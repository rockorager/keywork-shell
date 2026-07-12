#include <errno.h>
#include <lauxlib.h>
#include <lua.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "ext-idle-notify-v1-client-protocol.h"

#define CLIENT_MT "shell.wayland.client"

struct client;

struct event {
    struct event *next;
    uint32_t id;
    int idled;
};

struct watch {
    struct watch *next;
    struct client *client;
    struct ext_idle_notification_v1 *notification;
    uint32_t id;
};

struct client {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct ext_idle_notifier_v1 *notifier;
    struct watch *watches;
    struct event *events_head;
    struct event *events_tail;
    uint32_t next_id;
    int overflow;
};

static struct client *check_client(lua_State *L) {
    return luaL_checkudata(L, 1, CLIENT_MT);
}

static int push_error(lua_State *L, const char *message) {
    lua_pushnil(L);
    lua_pushstring(L, message);
    return 2;
}

static int push_errno(lua_State *L, const char *operation) {
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", operation, strerror(errno));
    return 2;
}

/* Protocol callbacks only append to this queue; Lua is touched by dispatch(). */
static void enqueue(struct watch *watch, int idled) {
    struct event *event = malloc(sizeof(*event));
    if (event == NULL) {
        watch->client->overflow = 1;
        return;
    }
    event->next = NULL;
    event->id = watch->id;
    event->idled = idled;
    if (watch->client->events_tail != NULL)
        watch->client->events_tail->next = event;
    else
        watch->client->events_head = event;
    watch->client->events_tail = event;
}

static void notification_idled(void *data, struct ext_idle_notification_v1 *unused) {
    (void)unused;
    enqueue(data, 1);
}

static void notification_resumed(void *data, struct ext_idle_notification_v1 *unused) {
    (void)unused;
    enqueue(data, 0);
}

static const struct ext_idle_notification_v1_listener notification_listener = {
    .idled = notification_idled,
    .resumed = notification_resumed,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
    struct client *client = data;
    if (client->seat == NULL && strcmp(interface, wl_seat_interface.name) == 0) {
        uint32_t supported = version < (uint32_t)wl_seat_interface.version
                                 ? version : (uint32_t)wl_seat_interface.version;
        client->seat = wl_registry_bind(registry, name, &wl_seat_interface, supported);
    } else if (client->notifier == NULL &&
               strcmp(interface, ext_idle_notifier_v1_interface.name) == 0) {
        uint32_t supported = version < (uint32_t)ext_idle_notifier_v1_interface.version
                                 ? version : (uint32_t)ext_idle_notifier_v1_interface.version;
        client->notifier = wl_registry_bind(
            registry, name, &ext_idle_notifier_v1_interface, supported);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void close_client(struct client *client) {
    struct watch *watch = client->watches;
    struct event *event = client->events_head;
    while (watch != NULL) {
        struct watch *next = watch->next;
        if (watch->notification != NULL)
            ext_idle_notification_v1_destroy(watch->notification);
        free(watch);
        watch = next;
    }
    while (event != NULL) {
        struct event *next = event->next;
        free(event);
        event = next;
    }
    if (client->notifier != NULL) ext_idle_notifier_v1_destroy(client->notifier);
    if (client->seat != NULL) wl_seat_destroy(client->seat);
    if (client->registry != NULL) wl_registry_destroy(client->registry);
    if (client->display != NULL) wl_display_disconnect(client->display);
    memset(client, 0, sizeof(*client));
}

static int client_fd(lua_State *L) {
    struct client *client = check_client(L);
    if (client->display == NULL) return 0;
    lua_pushinteger(L, wl_display_get_fd(client->display));
    return 1;
}

static int client_watch(lua_State *L) {
    struct client *client = check_client(L);
    lua_Number value = luaL_checknumber(L, 2);
    uint32_t timeout;
    struct watch *watch;
    if (client->display == NULL) return push_error(L, "Wayland client is closed");
    if (value != value || value < 0 || value > 4294967295.0 ||
        value != (lua_Number)(uint32_t)value)
        return luaL_argerror(L, 2, "expected a nonnegative uint32 integer");
    timeout = (uint32_t)value;
    watch = calloc(1, sizeof(*watch));
    if (watch == NULL) return push_error(L, "out of memory");
    if (client->next_id == 0) {
        free(watch);
        return push_error(L, "watch id space exhausted");
    }
    watch->client = client;
    watch->id = client->next_id++;
    watch->notification = ext_idle_notifier_v1_get_idle_notification(
        client->notifier, timeout, client->seat);
    if (watch->notification == NULL) {
        free(watch);
        return push_error(L, "failed to create idle notification");
    }
    ext_idle_notification_v1_add_listener(watch->notification, &notification_listener, watch);
    watch->next = client->watches;
    client->watches = watch;
    /* The Lua side watches readability only, so it cannot finish an EAGAIN flush. */
    if (wl_display_flush(client->display) < 0) {
        client->watches = watch->next;
        ext_idle_notification_v1_destroy(watch->notification);
        free(watch);
        return push_errno(L, "failed to flush Wayland display");
    }
    lua_pushnumber(L, watch->id);
    return 1;
}

static int client_dispatch(lua_State *L) {
    struct client *client = check_client(L);
    struct pollfd pollfd;
    int index = 1;
    if (client->display == NULL) return push_error(L, "Wayland client is closed");
    if (wl_display_dispatch_pending(client->display) < 0)
        return push_errno(L, "failed to dispatch pending Wayland events");
    /* keywork.loop deliberately gives a newly registered FD watch one
     * synthetic readable event so socket users can drain buffered data.
     * Verify the Wayland socket itself before calling the blocking dispatch
     * API, otherwise that first event could stall the whole shell. */
    pollfd.fd = wl_display_get_fd(client->display);
    pollfd.events = POLLIN;
    pollfd.revents = 0;
    if (poll(&pollfd, 1, 0) < 0) return push_errno(L, "failed to poll Wayland display");
    if (pollfd.revents != 0 && wl_display_dispatch(client->display) < 0)
        return push_errno(L, "failed to dispatch Wayland display");
    if (client->overflow) return push_error(L, "idle event queue overflow");
    lua_newtable(L);
    while (client->events_head != NULL) {
        struct event *event = client->events_head;
        client->events_head = event->next;
        lua_createtable(L, 0, 2);
        lua_pushnumber(L, event->id);
        lua_setfield(L, -2, "id");
        lua_pushstring(L, event->idled ? "idled" : "resumed");
        lua_setfield(L, -2, "state");
        lua_rawseti(L, -2, index++);
        free(event);
    }
    client->events_tail = NULL;
    return 1;
}

static int client_close(lua_State *L) {
    close_client(check_client(L));
    return 0;
}

static int wayland_connect(lua_State *L) {
    struct client *client = lua_newuserdata(L, sizeof(*client));
    memset(client, 0, sizeof(*client));
    client->next_id = 1;
    luaL_getmetatable(L, CLIENT_MT);
    lua_setmetatable(L, -2);
    client->display = wl_display_connect(NULL);
    if (client->display == NULL) {
        lua_pop(L, 1);
        return push_errno(L, "failed to connect to Wayland display");
    }
    client->registry = wl_display_get_registry(client->display);
    if (client->registry == NULL ||
        wl_registry_add_listener(client->registry, &registry_listener, client) < 0 ||
        wl_display_roundtrip(client->display) < 0) {
        close_client(client);
        lua_pop(L, 1);
        return push_errno(L, "failed to initialize Wayland registry");
    }
    if (client->seat == NULL || client->notifier == NULL) {
        const char *message = client->seat == NULL
            ? "Wayland compositor has no wl_seat" : "ext-idle-notify-v1 is unavailable";
        close_client(client);
        lua_pop(L, 1);
        return push_error(L, message);
    }
    return 1;
}

int luaopen_shell_wayland(lua_State *L) {
    static const luaL_Reg methods[] = {
        {"fd", client_fd}, {"watch", client_watch}, {"dispatch", client_dispatch},
        {"close", client_close}, {"__gc", client_close}, {NULL, NULL},
    };
    luaL_newmetatable(L, CLIENT_MT);
    luaL_register(L, NULL, methods);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, wayland_connect);
    lua_setfield(L, -2, "connect");
    return 1;
}
