# MegaPump Smart Contracts

Memecoin launchpad on MegaETH: instant token creation, bonding-curve trading in ETH, USDm or MEGA, and automatic graduation to the MegaPump DEX (Uniswap V2 fork).

## Deployed contracts (MegaETH, chain ID 4326)

| Contract | Address |
| --- | --- |
| MegaPump (UUPS proxy) | [`0xB6bC3988d62D2979b3ab7AABCcf3c9443f7dAbc4`](https://megaeth.blockscout.com/address/0xB6bC3988d62D2979b3ab7AABCcf3c9443f7dAbc4) |
| Implementation (v3) | [`0x244120fd15Dc60BB28DdB56e364deaf228E63fB9`](https://megaeth.blockscout.com/address/0x244120fd15Dc60BB28DdB56e364deaf228E63fB9) |
| GraduationLib | [`0x0f3e8D963CBf82060fe9E8F0d294e228Fd65489d`](https://megaeth.blockscout.com/address/0x0f3e8D963CBf82060fe9E8F0d294e228Fd65489d) |
| MegaPumpLens | [`0x03e5842F7e9a5006c84f34d4Ff477C96455c5B08`](https://megaeth.blockscout.com/address/0x03e5842F7e9a5006c84f34d4Ff477C96455c5B08) |
| MegaPump DEX Factory | [`0x4188aDbFfBec026EdE44F2C3A7E22beDD880a46f`](https://megaeth.blockscout.com/address/0x4188aDbFfBec026EdE44F2C3A7E22beDD880a46f) |
| MegaPump DEX Router | [`0xB24563A4ecF250C8238e41DF0af51D97734c1ec5`](https://megaeth.blockscout.com/address/0xB24563A4ecF250C8238e41DF0af51D97734c1ec5) |
| Owner (2-of-3 Safe) | [`0x2CBd81baCFFa7166A82023575f53CbC567B4e970`](https://megaeth.blockscout.com/address/0x2CBd81baCFFa7166A82023575f53CbC567B4e970) |

Every contract above is verified on Blockscout. The proxy was deployed on 9 July 2026 with the v1 implementation ([`0xFCBc25742Ae81ab38846065c62e228f5372122bf`](https://megaeth.blockscout.com/address/0xFCBc25742Ae81ab38846065c62e228f5372122bf)) and upgraded to v3 by the Safe on 14 October 2026.

## Architecture

- **MegaPumpFactory** (behind the UUPS proxy): token creation, either direct or prepared by the creator's signature and deployed by the first buy; bonding-curve buys and sells; fee routing (platform, creator, referrer) and claims; atomic graduation.
- **GraduationLib**: the graduation path, as an external library. When a token reaches its graduation amount, all of its liquidity moves to the MegaPump DEX in the same transaction, and the LP tokens are burned to the dead address.
- **BondingCurveMath**: the curve pricing, pure functions.
- **MegaPumpToken**: standard ERC-20 with permit, fixed 1B supply minted once at deployment.
- **MegaPumpLens**: read-only views for the website (price estimates, token info). No funds, no admin.
- **Launch currencies**: ETH by default. The owner can enable ERC-20 currencies (USDm, MEGA), each with its own graduation amount and fee. A token keeps the parameters that were set when it was created.

DEX contracts (Uniswap V2 fork with permissioned pair creation) live in [megapump-dex-contracts](https://github.com/MegaPumpETH/megapump-dex-contracts).

## Build & test

```bash
forge build
forge test
```

The files in `src/` are the exact sources verified on Blockscout. Build them with the settings in `foundry.toml` (solc 0.8.24, optimizer 200 runs, via IR) to reproduce the deployed bytecode.

Fork tests are skipped when no RPC is configured. The default profile runs 10,000 fuzz runs per property; CI uses `FOUNDRY_PROFILE=ci` (1,000).

`test/audit/` holds the tests written during the internal review of October 2026: real DEX bytecode, invariants, the upgrade from the deployed v1 bytecode, and a rehearsal of the mainnet upgrade. It is not an external audit.

## Security

See [mega-pump.fun/security](https://mega-pump.fun/security) for verified contract addresses, protocol guarantees, and what the admin can and cannot do.

## License

MIT
