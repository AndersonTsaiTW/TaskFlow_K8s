#!/bin/bash
set -e

echo "Running API smoke tests..."

# Ensure hurl is installed
if ! command -v hurl &> /dev/null
then
    echo "hurl could not be found. Please install it first."
    exit 1
fi

# Run tests
hurl --variable baseUrl="http://localhost:8000" --test tests/smoke-test.hurl

echo "Tests passed!"
