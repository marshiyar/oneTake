//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
#include <gtk/gtk.h>
#include <glib-unix.h>
#include <cairo.h>
#include <pango/pangocairo.h>

/* Helpers for things Swift cannot call directly (macros, varargs). */
static inline gulong mpvfx_connect(gpointer instance, const char *signal, GCallback cb, gpointer data) {
    return g_signal_connect_data(instance, signal, cb, data, NULL, (GConnectFlags)0);
}

static inline void mpvfx_error_box(GtkWindow *parent, const char *title, const char *message) {
    GtkWidget *d = gtk_message_dialog_new(parent, GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
                                          GTK_MESSAGE_ERROR, GTK_BUTTONS_OK, "%s", title);
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(d), "%s", message);
    gtk_window_set_title(GTK_WINDOW(d), title);
    gtk_dialog_run(GTK_DIALOG(d));
    gtk_widget_destroy(d);
}

/* Two-choice question. Returns 1 for `primary`, 0 for `secondary` (or the dialog was dismissed). */
static inline int mpvfx_choice_box(GtkWindow *parent, const char *title, const char *message, const char *primary, const char *secondary) {
    GtkWidget *d = gtk_message_dialog_new(parent, GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
                                          GTK_MESSAGE_QUESTION, GTK_BUTTONS_NONE, "%s", title);
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(d), "%s", message);
    gtk_dialog_add_button(GTK_DIALOG(d), secondary, 0);
    gtk_dialog_add_button(GTK_DIALOG(d), primary, 1);
    gtk_window_set_title(GTK_WINDOW(d), title);
    int r = gtk_dialog_run(GTK_DIALOG(d));
    gtk_widget_destroy(d);
    return r == 1;
}

static inline guint mpvfx_idle(GSourceFunc fn, gpointer data) {
    return g_idle_add_full(G_PRIORITY_DEFAULT, fn, data, NULL);
}

static inline void mpvfx_set_background(GtkWidget *w) {
    GtkCssProvider *p = gtk_css_provider_new();
    gtk_css_provider_load_from_data(p, "window, .mpvfx-canvas { background-color: #0a0a0a; color: #e5e5e5; }", -1, NULL);
    gtk_style_context_add_provider_for_screen(gtk_widget_get_screen(w), GTK_STYLE_PROVIDER(p),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(p);
}

/* GNOME's org.gnome.desktop.interface settings when the schema has `color-scheme` (GNOME 42+), else NULL. */
static inline GSettings *mpvfx_interface_settings(void) {
    static GSettings *s = NULL;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        GSettingsSchemaSource *src = g_settings_schema_source_get_default();
        GSettingsSchema *schema = src ? g_settings_schema_source_lookup(src, "org.gnome.desktop.interface", TRUE) : NULL;
        if (schema) {
            if (g_settings_schema_has_key(schema, "color-scheme")) s = g_settings_new("org.gnome.desktop.interface");
            g_settings_schema_unref(schema);
        }
    }
    return s;
}

/* 1 when the desktop prefers dark: GNOME color-scheme (prefer-dark / prefer-light win), else GTK's
   gtk-application-prefer-dark-theme or a dark theme variant name ("Adwaita-dark", "Adwaita:dark"). */
static inline int mpvfx_system_prefers_dark(void) {
    GSettings *s = mpvfx_interface_settings();
    if (s) {
        gchar *v = g_settings_get_string(s, "color-scheme");
        int dark = v && g_strcmp0(v, "prefer-dark") == 0, light = v && g_strcmp0(v, "prefer-light") == 0;
        g_free(v);
        if (dark) return 1;
        if (light) return 0;
    }
    GtkSettings *gs = gtk_settings_get_default();
    if (!gs) return 0;
    gboolean prefer = FALSE;
    gchar *name = NULL;
    g_object_get(gs, "gtk-application-prefer-dark-theme", &prefer, "gtk-theme-name", &name, NULL);
    int dark = prefer || (name && (g_str_has_suffix(name, "-dark") || g_str_has_suffix(name, "-Dark") || strstr(name, ":dark")));
    g_free(name);
    return dark;
}

/* Calls `cb` (instance, detail, data) whenever any input of mpvfx_system_prefers_dark changes. */
static inline void mpvfx_watch_system_appearance(GCallback cb) {
    GtkSettings *gs = gtk_settings_get_default();
    if (gs) {
        g_signal_connect(gs, "notify::gtk-application-prefer-dark-theme", cb, NULL);
        g_signal_connect(gs, "notify::gtk-theme-name", cb, NULL);
    }
    GSettings *s = mpvfx_interface_settings();
    if (s) g_signal_connect(s, "changed::color-scheme", cb, NULL);
}

/* Accept files dragged in from the file manager (text/uri-list). GTK answers the drag and fetches the data on drop;
   no default highlight (the app draws its own drop outline). */
static inline void mpvfx_enable_uri_drop(GtkWidget *w) {
    static GtkTargetEntry targets[] = { { (gchar *)"text/uri-list", 0, 0 } };
    gtk_drag_dest_set(w, (GtkDestDefaults)(GTK_DEST_DEFAULT_MOTION | GTK_DEST_DEFAULT_DROP), targets, 1, GDK_ACTION_COPY);
}

/* Window contents as PNG (smoke test). Returns cairo status, -1 if no GdkWindow. */
static inline int mpvfx_snapshot_window(GtkWidget *w, const char *path) {
    GdkWindow *gw = gtk_widget_get_window(w);
    if (!gw) return -1;
    int width = gdk_window_get_width(gw), height = gdk_window_get_height(gw);
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    cairo_t *cr = cairo_create(s);
    gtk_widget_draw(w, cr);
    cairo_destroy(cr);
    int status = cairo_surface_write_to_png(s, path);
    cairo_surface_destroy(s);
    return status;
}
