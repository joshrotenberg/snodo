# Changelog

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
