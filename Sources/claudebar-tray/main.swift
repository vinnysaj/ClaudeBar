import CAppIndicator

// On Wayland a client without keyboard focus can't take the clipboard, and the
// tray never has focus: the top bar draws its menu. Through XWayland, as an
// X11 client, it can copy the sign-in link.
gdk_set_allowed_backends("x11,*")
gtk_init(nil, nil)
let tray = Tray()
tray.start()
gtk_main()
