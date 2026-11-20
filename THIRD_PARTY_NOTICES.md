# Third-party notices

## pdf-inspector

Turnip includes compiled portions of
[`swiftlysingh/pdf-inspector`](https://github.com/swiftlysingh/pdf-inspector), a
fork of [`firecrawl/pdf-inspector`](https://github.com/firecrawl/pdf-inspector),
pinned to version 1.25.2 and source commit
`ac05c0c9d28a66de7a4dcaf14435e3138a8c444c`.

The included code is licensed under these terms:

```text
MIT License

Copyright (c) 2026 Firecrawl

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Adobe CMaps

The Apple binary embeds Adobe CMap data redistributed by `pdf-inspector` for
CID-encoded PDF text extraction. The embedded data is distributed under these
terms:

```text
%%Copyright: -----------------------------------------------------------
%%Copyright: Copyright 1990-2009 Adobe Systems Incorporated.
%%Copyright: All rights reserved.
%%Copyright:
%%Copyright: Redistribution and use in source and binary forms, with or
%%Copyright: without modification, are permitted provided that the
%%Copyright: following conditions are met:
%%Copyright:
%%Copyright: Redistributions of source code must retain the above
%%Copyright: copyright notice, this list of conditions and the following
%%Copyright: disclaimer.
%%Copyright:
%%Copyright: Redistributions in binary form must reproduce the above
%%Copyright: copyright notice, this list of conditions and the following
%%Copyright: disclaimer in the documentation and/or other materials
%%Copyright: provided with the distribution.
%%Copyright:
%%Copyright: Neither the name of Adobe Systems Incorporated nor the names
%%Copyright: of its contributors may be used to endorse or promote
%%Copyright: products derived from this software without specific prior
%%Copyright: written permission.
%%Copyright:
%%Copyright: THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%Copyright: CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%Copyright: INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
%%Copyright: MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%Copyright: DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
%%Copyright: CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%Copyright: SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
%%Copyright: NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%Copyright: LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%%Copyright: HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
%%Copyright: CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
%%Copyright: OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
%%Copyright: SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%Copyright: -----------------------------------------------------------
```

## encoding_rs data

The Apple binary includes encoding tables from `encoding_rs`. Those tables are
distributed under these terms:

```text
Copyright © WHATWG (Apple, Google, Mozilla, Microsoft).

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Rust dependencies

The crate license and notice texts for all five Apple targets are included in
[`RUST_THIRD_PARTY_LICENSES.md`](RUST_THIRD_PARTY_LICENSES.md). Distribute that
file together with this notice when redistributing the packaged engine.

The statically linked Rust standard library also has its own notices in
[`ThirdPartyLicenses/Rust/`](ThirdPartyLicenses/Rust/). Include that directory
when redistributing the engine. The generator copies the original standard-library
copyright document and license texts from the pinned Rust toolchain. The
upstream document includes platform-specific components beyond Apple targets.

The exact crate versions and checksums are fixed in
`Native/DocumentKitCore/Cargo.lock`. After preparing the pinned engine with
`Scripts/prepare-engine.sh`, regenerate the notices with Python 3.9 or later:

```sh
python3 Scripts/generate-rust-licenses.py
```

The generator uses Cargo's normal and build dependency trees for each Apple
target, excludes development-only dependencies, and collects the original
license and notice texts. Identical texts are listed once with their sources.
Codemagic checks that the committed inventory is current before a release.

`alloc-stdlib 0.2.4`, `include_dir 0.7.4`, and `include_dir_macros 0.7.4` omit
their workspace-root license files from their published crates. Copies in
`Scripts/LicenseOverrides/` come from each crate's recorded source revision:

- [alloc-stdlib license](https://github.com/dropbox/rust-alloc-no-stdlib/blob/ae42d22078b98549e987d2f03d12df7b984fde47/LICENSE)
- [include_dir and include_dir_macros license](https://github.com/Michael-F-Bryan/include_dir/blob/d742c6fffce99ee89da91b934e7ce6fb2a82680c/LICENSE)
