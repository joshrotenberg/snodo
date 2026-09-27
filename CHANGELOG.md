# Changelog

## [0.3.0](https://github.com/joshrotenberg/snodo/compare/v0.2.1...v0.3.0) (2026-09-27)


### ⚠ BREAKING CHANGES

* snodo_plug answers 411 to a request that declares Transfer-Encoding, without reading its body. Send request bodies with Content-Length, as the native listener already requires.
* a Tasks store started without :scope fails to start. Pass a scope function, or scope: :shared for the previous behavior.

### Bug Fixes

* apply the authorization policy to resource subscriptions and cache hints ([#117](https://github.com/joshrotenberg/snodo/issues/117)) ([27aaeeb](https://github.com/joshrotenberg/snodo/commit/27aaeeb0d84bfcc2ca5cd1e5ce5426198a84102d))
* authorize and validate task work before storing it ([#115](https://github.com/joshrotenberg/snodo/issues/115)) ([aad5c04](https://github.com/joshrotenberg/snodo/commit/aad5c044308a81c154923e8e1269aa90612c9790))
* bound HTTP connections and subscription streams ([#114](https://github.com/joshrotenberg/snodo/issues/114)) ([13b9352](https://github.com/joshrotenberg/snodo/commit/13b9352db01f87b855e8bae1af85d420acb7d4c8))
* bound integer literals in Snodo.Client HTTP responses ([#130](https://github.com/joshrotenberg/snodo/issues/130)) ([dd0cb23](https://github.com/joshrotenberg/snodo/commit/dd0cb234e82ab6ff521e66435a0b2a24d08256d8))
* bound integer literals, request ids, and progress tokens ([#118](https://github.com/joshrotenberg/snodo/issues/118)) ([a71e499](https://github.com/joshrotenberg/snodo/commit/a71e499bac14bf8a1f68a99d2fa9f95ecf7dd094))
* bound memory for an unterminated stdio line ([#125](https://github.com/joshrotenberg/snodo/issues/125)) ([e22a878](https://github.com/joshrotenberg/snodo/commit/e22a878c0a02f85b20b1c99f143581527e241bfa))
* bound Snodo.Client response sizes and page counts ([#119](https://github.com/joshrotenberg/snodo/issues/119)) ([6e1f785](https://github.com/joshrotenberg/snodo/commit/6e1f7857be988950be5b219ecf85ab9df14fe0fd)), closes [#88](https://github.com/joshrotenberg/snodo/issues/88)
* bound Tasks workers, task counts, lifetimes, and inputs ([#123](https://github.com/joshrotenberg/snodo/issues/123)) ([098b478](https://github.com/joshrotenberg/snodo/commit/098b47830e15319e519f5af5e8162cdcb5902f8b))
* bound the whole request body in snodo_plug ([#138](https://github.com/joshrotenberg/snodo/issues/138)) ([10789ba](https://github.com/joshrotenberg/snodo/commit/10789bae21e21e15ce06bd5cc19f9a8b9aa57df1))
* count only digits in the JSON integer literal limit ([#134](https://github.com/joshrotenberg/snodo/issues/134)) ([b2f049d](https://github.com/joshrotenberg/snodo/commit/b2f049db3a394ea37c8c2d4161244963de6b590a))
* make subscription filter checks linear and cap resource URIs ([#113](https://github.com/joshrotenberg/snodo/issues/113)) ([f125936](https://github.com/joshrotenberg/snodo/commit/f125936517f967b3a18a8ff17ff8ee942950f381))
* require an explicit scope in every Tasks store ([#121](https://github.com/joshrotenberg/snodo/issues/121)) ([bbc258f](https://github.com/joshrotenberg/snodo/commit/bbc258fe0d9d26e7720aefdb75ff1756a60034df))
* stop orphaned subscription workers and bound request bodies ([#135](https://github.com/joshrotenberg/snodo/issues/135)) ([0f1c8bf](https://github.com/joshrotenberg/snodo/commit/0f1c8bfbd77f38ae89e88a9e5bd0a3d65c7cf975)), closes [#127](https://github.com/joshrotenberg/snodo/issues/127)

## [0.2.1](https://github.com/joshrotenberg/snodo/compare/v0.2.0...v0.2.1) (2026-09-27)


### Features

* serve initialize-era clients over stdio ([#75](https://github.com/joshrotenberg/snodo/issues/75)) ([2a4d68c](https://github.com/joshrotenberg/snodo/commit/2a4d68c3cdfb35984748b5c73f623a00cdac4a4f))

## [0.2.0](https://github.com/joshrotenberg/snodo/compare/v0.1.0...v0.2.0) (2026-09-26)


### ⚠ BREAKING CHANGES

* tool content results carry kind :content instead of :resource.
* Snodo.Result has no error field, and Result.error/2 no longer takes an :error option.

### Features

* add Result.content/2 and deprecate Result.resource/2 (closes [#59](https://github.com/joshrotenberg/snodo/issues/59)) ([#72](https://github.com/joshrotenberg/snodo/issues/72)) ([68c9340](https://github.com/joshrotenberg/snodo/commit/68c9340e9ca4934283bea72c54fc386bf2ba9116))


### Bug Fixes

* accept a bare authorization module in Router.dispatch/5 (closes [#56](https://github.com/joshrotenberg/snodo/issues/56)) ([#65](https://github.com/joshrotenberg/snodo/issues/65)) ([456c816](https://github.com/joshrotenberg/snodo/commit/456c8160a05391b99eba1284131da2d9f5125d55))
* build the compliance report from the retained conformance run (closes [#62](https://github.com/joshrotenberg/snodo/issues/62)) ([#73](https://github.com/joshrotenberg/snodo/issues/73)) ([04e4685](https://github.com/joshrotenberg/snodo/commit/04e468514f73305b44130928311a6bf75426f0ec))
* deprecate Cancellation.cancel/2, whose reason is discarded (closes [#57](https://github.com/joshrotenberg/snodo/issues/57)) ([#70](https://github.com/joshrotenberg/snodo/issues/70)) ([3d9e1cd](https://github.com/joshrotenberg/snodo/commit/3d9e1cdc3d1a6f246bd2f36f683342fcf2fb7312))
* explain a disabled protocol in Snodo.Test.dispatch/2 (closes [#60](https://github.com/joshrotenberg/snodo/issues/60)) ([#66](https://github.com/joshrotenberg/snodo/issues/66)) ([3361a3d](https://github.com/joshrotenberg/snodo/commit/3361a3d8b962ce1b8ff6a56585c9c133655e9de0))
* validate the Snodo.Tool description at compile time (closes [#61](https://github.com/joshrotenberg/snodo/issues/61)) ([#67](https://github.com/joshrotenberg/snodo/issues/67)) ([45b0531](https://github.com/joshrotenberg/snodo/commit/45b0531a2d12c3b69d8975fd3f0adaaab48fbabb))


### Code Refactoring

* remove the unread error field from Snodo.Result (closes [#58](https://github.com/joshrotenberg/snodo/issues/58)) ([#71](https://github.com/joshrotenberg/snodo/issues/71)) ([30aad07](https://github.com/joshrotenberg/snodo/commit/30aad070566a08a206e6036a840c87b880f48534))

## 0.1.0 (2026-09-26)


### ⚠ BREAKING CHANGES

* rename mcp_ex to snodo ([#11](https://github.com/joshrotenberg/snodo/issues/11))

### Features

* add application authorization across discovery and dispatch ([#6](https://github.com/joshrotenberg/snodo/issues/6)) ([6e35765](https://github.com/joshrotenberg/snodo/commit/6e357655210f7f146c967f702e46be7f724866d5))
* add inline components and Simple resources and prompts ([#10](https://github.com/joshrotenberg/snodo/issues/10)) ([927d73d](https://github.com/joshrotenberg/snodo/commit/927d73d584031ce09e3c925f5b9408fd72681797))
* add MCP.Client for in-process dispatch ([#8](https://github.com/joshrotenberg/snodo/issues/8)) ([466fb8c](https://github.com/joshrotenberg/snodo/commit/466fb8cbd51f5b26b304441175230a72aaf387c8))
* add ordinary MRTR and elicitation workflows ([4914e1b](https://github.com/joshrotenberg/snodo/commit/4914e1b5097728cd4862749626750679d804d95e))
* add stdio and HTTP transports to MCP.Client ([#9](https://github.com/joshrotenberg/snodo/issues/9)) ([8d1d81e](https://github.com/joshrotenberg/snodo/commit/8d1d81e85c5bd3e4e6b1eceeb4d9360d3a4133ec))
* application stack, progress notifications, and conformance regression gate ([#1](https://github.com/joshrotenberg/snodo/issues/1)) ([d3b3041](https://github.com/joshrotenberg/snodo/commit/d3b3041e4164e8a3f4f4ad5e8912ad5f7edd4bf5))
* close the four target-application findings ([69f44a7](https://github.com/joshrotenberg/snodo/commit/69f44a7e0fad0299e852fb411671d5e308815cdb))
* mirror and validate Mcp-Param headers for x-mcp-header arguments (closes [#25](https://github.com/joshrotenberg/snodo/issues/25)) ([#40](https://github.com/joshrotenberg/snodo/issues/40)) ([ffa35c3](https://github.com/joshrotenberg/snodo/commit/ffa35c3b3369b55d4a9c48fb145b0396e40ff260))
* send clientInfo in request _meta from Snodo.Client (closes [#37](https://github.com/joshrotenberg/snodo/issues/37)) ([#47](https://github.com/joshrotenberg/snodo/issues/47)) ([3afe710](https://github.com/joshrotenberg/snodo/commit/3afe7107859e37ad9287de9c842a989987bf37f8))
* support initialize-era HTTP clients alongside 2026 (closes [#3](https://github.com/joshrotenberg/snodo/issues/3)) ([#4](https://github.com/joshrotenberg/snodo/issues/4)) ([bb43399](https://github.com/joshrotenberg/snodo/commit/bb433998ddaccb9ff0159b6ef149a994b6674e1b))


### Bug Fixes

* add Host validation and tighten Origin checks on HTTP transports (closes [#23](https://github.com/joshrotenberg/snodo/issues/23)) ([#33](https://github.com/joshrotenberg/snodo/issues/33)) ([638c26e](https://github.com/joshrotenberg/snodo/commit/638c26ea6cdeec49b05a62844f4f5aa5b629f860))
* bound stdio frame size and strip a leading BOM (closes [#21](https://github.com/joshrotenberg/snodo/issues/21)) ([#32](https://github.com/joshrotenberg/snodo/issues/32)) ([37ae8a5](https://github.com/joshrotenberg/snodo/commit/37ae8a5a65220ab0c85aed0cb9a4b13e7ce7ba44))
* do not answer JSON-RPC responses or malformed notifications (closes [#18](https://github.com/joshrotenberg/snodo/issues/18)) ([#28](https://github.com/joshrotenberg/snodo/issues/28)) ([3f92dd1](https://github.com/joshrotenberg/snodo/commit/3f92dd1d10c2ce2c61c506a5804cc804318f9a1c))
* harden URI template matching boundaries ([8d802fa](https://github.com/joshrotenberg/snodo/commit/8d802fa9044871e86bbada1b91ed79f94c6bab6d))
* keep initialize-era tools/list available when a tool has a non-object schema (closes [#24](https://github.com/joshrotenberg/snodo/issues/24)) ([#39](https://github.com/joshrotenberg/snodo/issues/39)) ([d093711](https://github.com/joshrotenberg/snodo/commit/d093711061d3f430c92ad487ce3d5f22cf241940))
* keep non-ASCII text intact over stdio ([#26](https://github.com/joshrotenberg/snodo/issues/26)) ([6f46a63](https://github.com/joshrotenberg/snodo/commit/6f46a63b655b6ea31b31378c1100d038700bf0a0))
* restore green CI on main ([#7](https://github.com/joshrotenberg/snodo/issues/7)) ([892788e](https://github.com/joshrotenberg/snodo/commit/892788e1b559f60d09e91d318239d460f20e16b5))
* restore the executor's :mcp_execution message tag ([#31](https://github.com/joshrotenberg/snodo/issues/31)) ([aa96bed](https://github.com/joshrotenberg/snodo/commit/aa96bede586a2012f25144829ec05af6e907449c))
* return tool input validation failures as isError results (closes [#13](https://github.com/joshrotenberg/snodo/issues/13)) ([#30](https://github.com/joshrotenberg/snodo/issues/30)) ([c48d6ea](https://github.com/joshrotenberg/snodo/commit/c48d6ea53632059ab4c4e66428e3550aff5eb828))
* treat client disconnect as cancellation in the Plug adapter (closes [#19](https://github.com/joshrotenberg/snodo/issues/19)) ([#34](https://github.com/joshrotenberg/snodo/issues/34)) ([740c1cb](https://github.com/joshrotenberg/snodo/commit/740c1cb2cb47c1b5efd340832ace1dfa0e1b00cc))
* use HTTP 200 for JSON-RPC errors on initialize-era dialects (closes [#14](https://github.com/joshrotenberg/snodo/issues/14)) ([#29](https://github.com/joshrotenberg/snodo/issues/29)) ([dbb3b5f](https://github.com/joshrotenberg/snodo/commit/dbb3b5f71218f2360765178d19815c11583d2b70))
* widen the sibling packages' dependency requirements ([#50](https://github.com/joshrotenberg/snodo/issues/50)) ([0413261](https://github.com/joshrotenberg/snodo/commit/04132617d849cd17a782a31e9843c4ecbd323782))


### Code Refactoring

* rename mcp_ex to snodo ([#11](https://github.com/joshrotenberg/snodo/issues/11)) ([84bf194](https://github.com/joshrotenberg/snodo/commit/84bf19430a89c1345f3daab41c2bd8ffc82e86fa))
