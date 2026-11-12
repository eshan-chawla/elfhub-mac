# Files

- [Local Development, Build Configuration, and Permissions](local-development-and-permissions.md) - How to build and run elfhub locally (Xcode only, never terminal xcodebuild), the xcconfig setup that keeps permissions stable, entitlements, the four macOS permissions and how they gate features, known warnings, and the project's code conventions.
- [Release Pipeline](release-pipeline.md) - How scripts/release.sh ships elfhub. It picks the next version from GitHub Releases, archives and exports with Developer ID, builds a DMG, notarizes and staples it, and publishes a GitHub Release. The app has no update feed.
