.PHONY: check docs-check

# Pre-merge gate (auto-detected by /fix-review). Extend with go vet / go test -race once code lands.
check: docs-check

docs-check:
	tumanomir check docs/
