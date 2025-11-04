# Contributing to CKSwiftData

Thanks for your interest in CKSwiftData! 👋

## Found a Bug? 🐛

Please [open an issue](https://github.com/stalkermv/CKSwiftData/issues/new/choose) with:
- What you expected to happen
- What actually happened
- Steps to reproduce (code snippets welcome!)
- Environment details (platform, Swift version)

Screenshots or stack traces make debugging even faster.

## Ready to Contribute? 🚀

1. **Fork and clone**
   ```bash
   git clone https://github.com/YOUR_USERNAME/CKSwiftData.git
   cd CKSwiftData
   ```

2. **Create a branch**
   ```bash
   git checkout -b feature/your-awesome-idea
   ```

3. **Make your changes**
   - Keep code style consistent with the existing codebase
   - Prefer adding DocC comments for new public APIs
   - Update or add tests when introducing new behavior

4. **Verify locally**
   ```bash
   swift build
   swift test --parallel
   ```

5. **Open a pull request**
   - Push your branch and submit a PR against `main`
   - Describe the change and link related issues
   - The CI workflow must pass before the PR can be merged

## Code Style Guidelines

- Use Apple's standard naming conventions
- Avoid force unwraps unless you are absolutely sure
- Organize extensions by protocol conformance when possible
- Document macros and user-facing types with `///` comments

## Commit Messages

- Keep them concise yet descriptive (e.g. `Add Relationship projected value docs`)
- Reference GitHub issues when applicable (e.g. `Fix #42`)

## Release Process

1. Update [`CHANGELOG.md`](CHANGELOG.md)
2. Bump the version in `Package.swift`
3. Create a GitHub release with notes from the changelog

## Questions?

- Open an issue
- Ping [@stalkermv](https://github.com/stalkermv) on GitHub
- Or ask in your pull request

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).

Thanks again for helping CKSwiftData grow! 🎉
