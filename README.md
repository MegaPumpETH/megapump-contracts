# MegaPump — Smart Contracts

Memecoin launchpad on MegaETH — instant token creation, bonding curve trading, and automatic graduation to the MegaPump DEX (Uniswap V2 fork).

## Architecture

- **MegaPumpFactory** (UUPS proxy) — token creation, bonding curve pricing, buys/sells, fee routing, and atomic graduation
- **MegaPumpToken** — standard ERC-20 with permit, fixed 1B supply, minted once at deployment
- **Graduation** — when a token reaches its threshold, all liquidity migrates in a single transaction to the MegaPump DEX; the LP is burned to the dead address

DEX contracts (Uniswap V2 fork with permissioned pair creation) live in [megapump-dex-contracts](https://github.com/MegaPumpETH/megapump-dex-contracts).

## Build & Test

```bash
forge build
forge test
```

## Security

See [mega-pump.fun/security](https://mega-pump.fun/security) for verified contract addresses, protocol guarantees, and what the admin can and cannot do.

## License

MIT