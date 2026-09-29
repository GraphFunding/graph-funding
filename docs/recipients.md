# Recipients and where each address comes from

Checked on 2026-09-29. Each address was read from the project's official donation page (raw HTML or rendered page) and
checked on-chain with `cast`: checksum, code size, forward and reverse ENS, and a simulated 0.001 ETH transfer. The
contract stores the resolved address, never the ENS name. **None of these projects has endorsed Graph Funding.**

| Branch | Project | Address | Official source | Type |
|---|---|---|---|---|
| Core protocol | Protocol Guild (1-year vesting) | `0x4EA88fa76848a8BBAB72613d4171df1eBcf68399` (`theprotocolguild.eth`) | https://protocol-guild.readthedocs.io/en/latest/03-donate.html | 0xSplits vesting |
| Core protocol | Lighthouse | `0x25c4a76E7d118705e7Ea2e9b7d8C59930d8aCD3b` (`donation.sigmaprime.eth`) | https://github.com/sigp/lighthouse#donations | EOA |
| Core protocol | Nimbus | `0x70E47C843E0F6ab0991A3189c28F2957eb6d3842` | https://github.com/status-im/nimbus-eth2#donations | EOA |
| Core protocol | Lodestar | `0xb4Da52336092Db22fe8e036866d59C6488604f89` | https://github.com/ChainSafe/lodestar/blob/unstable/.github/FUNDING.yml | Safe 3/5 |
| Privacy | Tor Project | `0x532Fb5D00f40ced99B16d1E295C77Cda2Eb1BB4F` | https://donate.torproject.org/cryptocurrency/ | EOA |
| Privacy | Web3Privacy Now | `0xB8Fbd9A43cc0CeB3d9ddd58b752979a77e6f0c1D` (`web3privacynow.eth`) | https://web3privacy.info/donate | EOA |
| Privacy | Whonix | `0xf9d352E30dE38eD1173854a241074414CEa19555` | https://www.whonix.org/wiki/Donate/Crypto | EOA |
| Security | Revoke.cash | `0xfcBf17200C64E860F6639aa12B525015d115F863` (`revokecash.eth`) | https://revoke.cash (footer) | EOA |
| Security | SEAL 911 | `0xba5Ed9942ea64e8D789187E0aF6a0390d78BA5ed` | https://github.com/security-alliance/seal-911#donations | Safe 3/5 |
| Security | DeFiHackLabs | `0xD7d6215b4EF4b9B5f40baea48F41047Eb67a11D5` | https://github.com/SunWeb3Sec/DeFiHackLabs#donate-us | EOA |
| Open tooling & data | L2BEAT | `0x41626BA92c0C2a1aD38fC83920300434082B1870` (`l2beat.eth`) | https://l2beat.com/donate | EOA |
| Open tooling & data | growthepie | `0x9438b8B447179740cD97869997a2FCc9b4AA63a2` (`growthepie.eth`) | https://www.growthepie.com/donate | EOA |
| Open tooling & data | Otterscan | `0x35D1A101E55DA0C641e9379f2e4dfA3e2AE7F37b` (`otterscan.eth`) | https://github.com/otterscan/otterscan#donation-address | EOA |
| Open tooling & data | rotki | `0x9531C059098e3d194fF87FebB587aB07B30B1306` (`rotki.eth`) | https://github.com/rotki/rotki#donations | EOA |

Left out on purpose: `protocolguild.eth` and `seal911.eth` (they resolve to addresses that the projects' official pages
do not list), an old DefiLlama address, and Grandine (official address that has never been used). Safes need more than
2,300 gas to receive ETH; `payout` forwards all gas and falls back to WETH if the recipient refuses ETH.
