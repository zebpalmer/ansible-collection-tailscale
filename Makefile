SHELL := /bin/bash

.PHONY: help lint release patch minor major push \
        check-branch check-dirty check-clean pre-release post-release \
        prompt-type do-release cleanup-tmp

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## Linting
lint: ## Run ansible-lint
	ansible-lint

## Release Management
release: cleanup-tmp check-branch check-dirty prompt-type pre-release do-release post-release cleanup-tmp ## Create a release (interactive or: make release TYPE=patch|minor|major)
	@echo ""
	@echo "================================"
	@echo "Release complete!"
	@echo "================================"

patch: ## Bump patch version (0.0.X)
	$(call bump-version,patch,3)

minor: ## Bump minor version (0.X.0)
	$(call bump-version,minor,2)

major: ## Bump major version (X.0.0)
	$(call bump-version,major,1)

######### Internal Helpers (not shown in help) #########

pre-release: check-branch check-clean

post-release: push

define bump-version
	@CURRENT=$$(grep '^version:' galaxy.yml | awk '{print $$2}'); \
	case $(1) in \
		patch) NEW=$$(echo $$CURRENT | awk -F. '{$$3+=1; print $$1"."$$2"."$$3}' OFS=.) ;; \
		minor) NEW=$$(echo $$CURRENT | awk -F. '{$$2+=1; $$3=0; print $$1"."$$2"."$$3}' OFS=.) ;; \
		major) NEW=$$(echo $$CURRENT | awk -F. '{$$1+=1; $$2=0; $$3=0; print $$1"."$$2"."$$3}' OFS=.) ;; \
	esac; \
	echo "Bumping $$CURRENT -> $$NEW"; \
	sed -i '' "s/^version: .*/version: $$NEW/" galaxy.yml && \
	sed -i '' "s/version: \"[0-9]*\.[0-9]*\.[0-9]*\"/version: \"$$NEW\"/g" README.md && \
	git add galaxy.yml README.md && \
	git commit -m "Release $$NEW" && \
	git tag -a "$$NEW" -m "Release $$NEW" && \
	echo "Tagged $$NEW"
endef

prompt-type:
	@CURRENT=$$(grep '^version:' galaxy.yml | awk '{print $$2}'); \
	V_PATCH=$$(echo $$CURRENT | awk -F. '{$$3+=1; print $$1"."$$2"."$$3}' OFS=.); \
	V_MINOR=$$(echo $$CURRENT | awk -F. '{$$2+=1; $$3=0; print $$1"."$$2"."$$3}' OFS=.); \
	V_MAJOR=$$(echo $$CURRENT | awk -F. '{$$1+=1; $$2=0; $$3=0; print $$1"."$$2"."$$3}' OFS=.); \
	if [ -z "$(TYPE)" ]; then \
		echo ""; \
		echo "Current version: $$CURRENT"; \
		echo ""; \
		echo "Select release type:"; \
		echo "  patch  - Bug fixes          -> $$V_PATCH"; \
		echo "  minor  - New features       -> $$V_MINOR"; \
		echo "  major  - Breaking changes   -> $$V_MAJOR"; \
		echo ""; \
		read -p "Enter release type [patch/minor/major]: " choice; \
		case $$choice in \
			patch|minor|major) ;; \
			*) echo "ERROR: Invalid choice '$$choice'. Must be patch, minor, or major."; rm -f .release-type.tmp; exit 1 ;; \
		esac; \
		echo "$$choice" > .release-type.tmp; \
	else \
		if [ "$(TYPE)" != "patch" ] && [ "$(TYPE)" != "minor" ] && [ "$(TYPE)" != "major" ]; then \
			echo "ERROR: Invalid TYPE '$(TYPE)'"; \
			echo "Must be: patch, minor, or major"; \
			exit 1; \
		fi; \
		echo "$(TYPE)" > .release-type.tmp; \
	fi

do-release:
	@RELEASE_TYPE=$$(cat .release-type.tmp 2>/dev/null) || { \
		echo "ERROR: Failed to read release type"; \
		rm -f .release-type.tmp; \
		exit 1; \
	}; \
	[ -n "$$RELEASE_TYPE" ] || { \
		echo "ERROR: Release type is empty"; \
		rm -f .release-type.tmp; \
		exit 1; \
	}; \
	if [ "$$RELEASE_TYPE" = "major" ]; then \
		echo ""; \
		echo "========================================"; \
		echo "WARNING: MAJOR RELEASE"; \
		echo "========================================"; \
		echo "This will create a BREAKING CHANGE release."; \
		echo "Major releases indicate incompatible API changes."; \
		echo ""; \
		read -p "Are you sure you want to continue? [y/N]: " confirm; \
		case $$confirm in \
			[Yy]*) echo "Proceeding with major release..." ;; \
			*) echo "Release cancelled."; rm -f .release-type.tmp; exit 1 ;; \
		esac; \
		echo ""; \
	fi; \
	$(MAKE) $$RELEASE_TYPE

cleanup-tmp:
	@rm -f .release-type.tmp

check-branch:
	@if [ "$$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then \
		echo "ERROR: You are not on the 'main' branch. Aborting."; \
		exit 1; \
	fi

check-dirty:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "ERROR: Uncommitted changes detected. Commit or stash changes before starting a release."; \
		exit 1; \
	fi

check-clean:
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "ERROR: Git working directory is not clean. Commit or stash changes first."; \
		exit 1; \
	fi

push:
	git push && git push --tags
