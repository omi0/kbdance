PREFIX ?= $(HOME)/.local/bin

.PHONY: build install uninstall app test

# Command-line tool.
build:
	swift build -c release --product kbdance

install: build
	install -d "$(PREFIX)"
	install -m 755 .build/release/kbdance "$(PREFIX)/kbdance"
	@echo "Installed to $(PREFIX)/kbdance"

uninstall:
	rm -f "$(PREFIX)/kbdance"

# Menu bar app: builds KeyboardDance.app, installs it to ~/Applications and opens it.
app:
	./build-app.sh

test:
	swift test
