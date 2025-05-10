all: build

build:
	dub build --compiler ldc2 --debug debug
