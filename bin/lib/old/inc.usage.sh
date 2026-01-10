#!/bin/sh

usage() {
  echo ""
  echo ""
  echo ""
  echo "Run cibuild in $(pwd)"
  echo " Usage:"
  echo ""
  echo " $(basename "${0}") -r [RUN]"
  echo ""
  echo "  Args:"
  echo "   -h, --help        --> shows usage"
  echo "   -v, --version     --> shows version"
  echo "   -r, --run         --> run: check|build|test|deploy|main"
  echo ""
}
