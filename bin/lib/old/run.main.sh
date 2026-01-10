#!/bin/sh

# for local or single-stage ci usage
main() {
  log 2 "run: main"
  check
  build
  test
  deploy
}
