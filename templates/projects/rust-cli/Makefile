export time=$(shell date +%FT%T)
export version=$(shell git rev-parse --short HEAD 2>/dev/null)

.PHONY: build
build:
	@BUILD_TIME=$(time) PROJECT_VERSION=$(version) cargo build --release

.PHONY: run
run:
	@cargo run --release

.PHONY: clean
clean:
	@cargo clean

.PHONY: test
test:
	@cargo test -- --showoutput
