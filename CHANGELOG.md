# Changelog

Notable changes to Vibechar. Versions follow Semantic Versioning; release notes
are generated from Conventional Commits. Earlier `build-*` archives predate versioned releases.

## [1.0.0](https://github.com/rovnyart/vibechar/releases/tag/v1.0.0) — 2026-11-17

### Added

- add scratch buffers and Mac session recovery ([8fab1af](https://github.com/rovnyart/vibechar/commit/8fab1af5c1481b76414ff2d273f3ce35ad6853e3))
- persist and restore terminal sessions ([8bc375a](https://github.com/rovnyart/vibechar/commit/8bc375a9e490afd9bb3495517edd13cf992debbe))
- bring Pocket interface to the native Mac app ([9cb7fa8](https://github.com/rovnyart/vibechar/commit/9cb7fa8b8d7a3ddd8bfae2e90bd477c8ea03de88))
- add private scratches to Mac and terminal ([fc4dbae](https://github.com/rovnyart/vibechar/commit/fc4dbaeabde83cbdc6dac5283001c66a63436125))
- add local Secret Drop for agent commands ([98e7f62](https://github.com/rovnyart/vibechar/commit/98e7f62d02560d75387b0e4ff7c27563f0ee0b1f))
- add Save As to Mac and terminal ([77702fe](https://github.com/rovnyart/vibechar/commit/77702fe4572aacf35702908a69cf7238632b4c75))
- group typing and deletion undo in Mac and terminal ([d303567](https://github.com/rovnyart/vibechar/commit/d303567ca9d81071328e0475de94e49054103bd5))
- add smart local syntax and Pocket language picker ([23c593e](https://github.com/rovnyart/vibechar/commit/23c593ea770c0d64e5000a72d6a5ada71294a365))
- add terminal selections and clipboard editing ([38fb337](https://github.com/rovnyart/vibechar/commit/38fb3370b6b004c99a91b7abcb73d35b6e07c1d0))
- add shared local find and replace with batch previews ([5a7827e](https://github.com/rovnyart/vibechar/commit/5a7827e39a919f75b9fccab7072188d6172e68b0))
- add shared local text tools and Pocket command palette ([8df54bd](https://github.com/rovnyart/vibechar/commit/8df54bda803b6d263a2462c56a78aaf95b44bf00))
- add Unicode case and URL tools with compact palette scrolling ([68af1b4](https://github.com/rovnyart/vibechar/commit/68af1b4a887745d6ae07c7b515105536937029aa))
- add shared multicursor editing to Mac and terminal ([2c28253](https://github.com/rovnyart/vibechar/commit/2c2825381f9109df7e00174b75262aaf8e7ca64b))
- add Command-T for new Mac tabs ([711ca92](https://github.com/rovnyart/vibechar/commit/711ca928c9285f057e516a17284a188ad5f71025))
- switch Mac tabs with Command-number shortcuts ([225ae65](https://github.com/rovnyart/vibechar/commit/225ae65c8ea6d46622983217cd6b8b8f70002118))
- add shared indentation, wrapping and cursor position ([a44a6e1](https://github.com/rovnyart/vibechar/commit/a44a6e164d7cd1bb80930c157312eedb2fedf566))
- add line numbers and shared text statistics ([df2b899](https://github.com/rovnyart/vibechar/commit/df2b899e54fd51e975d1930628336434f3545616))
- add adaptive large-text mode ([084318d](https://github.com/rovnyart/vibechar/commit/084318d4fa2e6abe24a426f227eb74a6f58dee38))
- **mac**: add secure OpenAI connection settings ([2819b61](https://github.com/rovnyart/vibechar/commit/2819b61fa005c23e8c0032ace050defed5982e5c))
- **mac**: preview and apply AI selection rewrites ([6259bfa](https://github.com/rovnyart/vibechar/commit/6259bfa83834b7bea7051afc4f6aeb7191db37f7))
- **mac**: learn local row recipes from examples ([091bf4f](https://github.com/rovnyart/vibechar/commit/091bf4fb44f87b62cd3a6b1f4511ed7d312353d4))
- **mac**: save recipes and replay them offline ([8aa36fe](https://github.com/rovnyart/vibechar/commit/8aa36fe547e3eac6ac3b16789f593820dae97485))
- **mac**: add Graphite app icon with native packaging ([1ceecf2](https://github.com/rovnyart/vibechar/commit/1ceecf2c55290cbced23321b96a42f1b48c391e8))
- publish Vibechar with unified vc launcher and release pipeline ([c46f0a9](https://github.com/rovnyart/vibechar/commit/c46f0a940893a0d6e775bad17b7c8cb38791f6b8))
- **release**: add semantic versions and one-click Mac updates ([e5b01b3](https://github.com/rovnyart/vibechar/commit/e5b01b310351457524f26ec01138a5c89254288e))

### Fixed

- leave private mode after successful file save ([7b12e63](https://github.com/rovnyart/vibechar/commit/7b12e63101d8c8fb6e58e450d62fb3b71cdaf987))
- close the Mac window when its last tab closes ([0b332c9](https://github.com/rovnyart/vibechar/commit/0b332c993a875efcb3af50aa4ac5a83f1730b596))
- separate terminal scrolling from caret and add mouse clicks ([d33acac](https://github.com/rovnyart/vibechar/commit/d33acacd0bbcf6b03958ce6cbe5e6c11799a2e29))
- checkpoint Mac selection without flashing save status ([f652b59](https://github.com/rovnyart/vibechar/commit/f652b5986bf5d5a627c03d2f78f228a6c5c16a7e))
- spread clipboard lines across matching carets ([13f233f](https://github.com/rovnyart/vibechar/commit/13f233faa36ae6557a788c89628f1b2fa6280b18))
- **mac**: show masked identity for saved API keys ([5acc7ee](https://github.com/rovnyart/vibechar/commit/5acc7ee3f0ca1d9501c967e4d24ef5562725a672))
- **ci**: use current Mac toolchains and synchronize terminal fixtures ([912077a](https://github.com/rovnyart/vibechar/commit/912077ae64c51321c5270b10e6acd811d3c3a0e3))
- validate fresh installs and isolate native CI credentials ([7b56a52](https://github.com/rovnyart/vibechar/commit/7b56a52c4e121810b04caf0371f7510ac03581e2))
- **ci**: retain optimized native assertion diagnostics ([dce84d2](https://github.com/rovnyart/vibechar/commit/dce84d2d5bc97e50c21ebbb94af7af2526c5c3cd))
- **mac**: stabilize editor geometry with classic scrollbars ([e9cdc62](https://github.com/rovnyart/vibechar/commit/e9cdc62b5d39aa987b6728d15ca95c391e127274))
- **ci**: isolate Save As destination tests and use portable lipo arguments ([ba6e241](https://github.com/rovnyart/vibechar/commit/ba6e2416abacc7411b6cf59e370f56d2a542f0ac))
- **ci**: isolate native AI suites and finish AppKit startup ([71b1943](https://github.com/rovnyart/vibechar/commit/71b1943792736f36a6eea2f810a89785af060786))

### Performance

- bound shared undo and redo history retention ([b054947](https://github.com/rovnyart/vibechar/commit/b05494770e931f0b664e798710342e1f56af2908))
- avoid full-line scans and copies during editing ([451bceb](https://github.com/rovnyart/vibechar/commit/451bcebbf98900fcf759cb723b57f2285aa7502e))
- patch native history and tune AppKit layout ([d8d7896](https://github.com/rovnyart/vibechar/commit/d8d789652ebd451d1aa900a622ee0ab2fb619839))
- avoid duplicate initial AppKit layout ([ace0690](https://github.com/rovnyart/vibechar/commit/ace0690e8595ab98a956c0094d2d5aa44a11b7ea))

### Changed

- explore three native Mac interface directions ([398db6f](https://github.com/rovnyart/vibechar/commit/398db6f867049c63a1bc80e6cb41cb2baf521edf))
- approve Pocket direction and V_ identity ([a662fa9](https://github.com/rovnyart/vibechar/commit/a662fa990d621d7442a4d300146557359bcc8b11))
- cover selected JSON formatting with surrounding text ([94b2108](https://github.com/rovnyart/vibechar/commit/94b210865bd9d7aaa46ccf6f68d7d4e4dde26199))
- scope AI to Mac settings first ([62101c7](https://github.com/rovnyart/vibechar/commit/62101c71492a2f6c923995ff492a736fc0543b09))
- record verified public release and installer checks ([38692b3](https://github.com/rovnyart/vibechar/commit/38692b333aae70d8f8a42d414463e3b68dd77f87))
- target Apple Silicon for Mac releases ([baae5a7](https://github.com/rovnyart/vibechar/commit/baae5a7af6e4c782a2db0f8e04942c2e5225bfdd))
- record verified Apple Silicon release ([0114516](https://github.com/rovnyart/vibechar/commit/0114516943323576853f521290552add9d0266f9))
- **release**: publish manually with a generated changelog ([7075150](https://github.com/rovnyart/vibechar/commit/7075150640de400cda2f4f23a52121da72eb32dc))

