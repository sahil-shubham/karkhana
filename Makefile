.PHONY: dev-server dev-ui build clean install-deps

dev-server:
	go run ./cmd/karkhana

dev-ui:
	cd ui && npm run dev

install-deps:
	go mod tidy
	cd ui && npm install

build-ui:
	cd ui && npm run build

build: build-ui
	go build -o bin/karkhana ./cmd/karkhana

clean:
	rm -rf bin/ ui/dist/ ui/node_modules/

fmt:
	gofmt -w -s .
	cd ui && npx prettier --write src/

vet:
	go vet ./...
