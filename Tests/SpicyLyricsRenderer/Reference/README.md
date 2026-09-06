# Independent desktop gradient reference

`kawarp-1.2.0.js` is the unmodified `dist/index.js` in the MIT-licensed
[`@kawarp/core` 1.2.0 npm tarball](https://registry.npmjs.org/@kawarp/core/-/core-1.2.0.tgz).
Its SHA-256 is `f36a99dcb0d9167d450d1009ff6e4a0f1659b17352cd1be0644f0a26e1a58cc5`.
Tarball SHA-1: `5bbec5eec4dbf3498aa9f54eec059060839525b5`.
The package's license is retained in `KAWARP-LICENSE`.

This is the version pinned by the inspected desktop Spicy Lyrics lockfile.
The options in `../pc-gradient-reference.js` are independently transcribed from
`src/components/DynamicBG/dynamicBackground.ts` at desktop commit
`4576d022b39e98291d71c75b0d4d355bcc332ced`. Desktop does not resize the canvas
backing store: its default 300x150 is stretched to the container by CSS.
The fullscreen filter is `saturate(2.5) brightness(.65)`.

The reference runs separately from the shipping gradient adapter. Do not modify
the oracle or regenerate it from the implementation to make a regression pass.
