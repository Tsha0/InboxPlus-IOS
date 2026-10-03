# Third-party inventory

The generated [CycloneDX SBOM](sbom.cdx.json) lists dependency versions, licenses,
artifact hashes, and source locations. Regenerate it with:

```bash
swift run MimoRuntimeCLI sbom --output docs/sbom.cdx.json
```

Dependency pins are defined in:

- [`Package.swift`](../Package.swift)
- [`Runtime/Synapse/runtime-manifest.json`](../Runtime/Synapse/runtime-manifest.json)
- [`Runtime/Synapse/requirements.lock`](../Runtime/Synapse/requirements.lock)
- [`Sources/MimoBridge/BridgeCatalog.swift`](../Sources/MimoBridge/BridgeCatalog.swift)
- [`Sources/MimoBridgeService/LibolmProvisioner.swift`](../Sources/MimoBridgeService/LibolmProvisioner.swift)

CPython is host-provided under the PSF-2.0 license.

Brand-mark SVGs in [`Scripts/brand-icons`](../Scripts/brand-icons) are from
[Simple Icons](https://simpleicons.org), version 13.20.0, under CC0-1.0.
The depicted marks remain trademarks of their respective owners; no affiliation
or endorsement is claimed.
