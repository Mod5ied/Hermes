.PHONY: build run test clean deps sign-adhoc bundle cert

APP=bin/hermes
BUNDLE=Hermes.app
SPEECH_SWIFT=internal/speech/libspeechswift.a

# Stable code signing identity for local development.
# A self-signed certificate keeps macOS TCC grants valid across rebuilds.
# Run `make cert` to create one; otherwise the bundle is ad-hoc signed and
# permissions must be reset after each rebuild.
CERT_KEYCHAIN ?= $(PWD)/HermesSigning.keychain-db
CERT_NAME ?= Hermes Code Signing

$(SPEECH_SWIFT): internal/speech/speech_analyzer.swift
	@echo "Checking SpeechAnalyzer SDK availability..."
	@echo "SDK: $$(xcrun --show-sdk-version) ($$(xcrun --show-sdk-path))"
	@echo "Toolchain: $$(swiftc --version 2>/dev/null | grep 'Apple Swift' | head -n1)"
	@SDK=$$(xcrun --show-sdk-version); \
	MAJOR=$$(echo $$SDK | cut -d. -f1); \
	if [ "$$MAJOR" -lt 26 ]; then \
		echo "ERROR: SDK $$SDK does not include macOS 26 SpeechAnalyzer. Required: macOS 26+."; \
		echo "Install Xcode 16 / macOS 26 SDK or later."; \
		exit 1; \
	fi
	@which swiftc > /dev/null || (echo "ERROR: swiftc not found"; exit 1)
	swiftc -target arm64-apple-macosx26.0 -emit-library -static -o $@ $<

build: $(SPEECH_SWIFT)
	@mkdir -p bin
	go build -o $(APP) ./cmd/hermes

bundle: build
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(APP) $(BUNDLE)/Contents/MacOS/
	cp Info.plist $(BUNDLE)/Contents/
	cp assets/AppIcon.icns $(BUNDLE)/Contents/Resources/
	@if [ -f "$(CERT_KEYCHAIN)" ]; then \
		echo "Signing with '$(CERT_NAME)' ..."; \
		codesign --force --deep --keychain "$(CERT_KEYCHAIN)" --sign "$(CERT_NAME)" $(BUNDLE); \
	else \
		echo "WARNING: No $(CERT_KEYCHAIN) found; using ad-hoc signature."; \
		echo "         macOS permissions may need to be reset after each rebuild."; \
		echo "         Run 'make cert' to create a self-signed certificate for stable grants."; \
		codesign --force --deep --sign "-" $(BUNDLE); \
	fi

cert:
	./scripts/setup-codesign.sh

run: build
	./$(APP)

test:
	go test ./...

clean:
	rm -rf bin
	rm -rf $(BUNDLE)

deps:
	go get github.com/kbinani/screenshot
	go get golang.org/x/image/draw
	go get golang.design/x/hotkey
	go get github.com/ledongthuc/pdf
	go get github.com/stretchr/testify

sign-adhoc:
	codesign --force --deep --sign - $(APP)

# Deploy the Hermes Pass Cloudflare Worker.
# Requires CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID env vars (or
# wrangler configuration) and that Worker secrets are already set via
# `wrangler secret put`.
deploy-proxy:
	cd hermes/proxy && npm ci && npx wrangler deploy
