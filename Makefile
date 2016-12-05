PREFIX = /usr
PROGNAME = WifiKeyboardPerl

build:
	true

install:
	install -m 0755 $(PROGNAME).pl $(PREFIX)/bin/$(PROGNAME)
