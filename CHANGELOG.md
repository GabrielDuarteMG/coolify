# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- Replace the release process
    - Select the stage and the version with `scripts/release.sh`, which offers the versions the branch allows and preselects the bump the commits need
    - Decide the version, the releases and the moving tags with `scripts/version.sh`, which also reports what a push publishes

### Removed

- Remove the git-cliff workflow that generated `CHANGELOG.md`, it is written by hand
