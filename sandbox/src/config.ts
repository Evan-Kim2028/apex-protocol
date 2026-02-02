/**
 * APEX Protocol Configuration
 *
 * Network addresses and configuration for DeepBook integration
 */

export type Network = 'mainnet' | 'testnet' | 'localnet';

export interface NetworkConfig {
  rpcUrl: string;
  deepbook: {
    package: string;
    marginPackage: string;
  };
  // Well-known pool addresses (populate after discovery)
  pools: {
    suiUsdc?: string;
    suiUsdt?: string;
    deepSui?: string;
  };
  // Common token types
  tokens: {
    sui: string;
    usdc: string;
    usdt: string;
    deep: string;
  };
}

export const CLOCK_OBJECT = '0x6';

export const NETWORKS: Record<Network, NetworkConfig> = {
  mainnet: {
    rpcUrl: 'https://fullnode.mainnet.sui.io:443',
    deepbook: {
      package: '0x2d93777cc8b67c064b495e8606f2f8f5fd578450347bbe7b36e0bc03963c1c40',
      marginPackage: '0x97d9473771b01f77b0940c589484184b49f6444627ec121314fae6a6d36fb86b',
    },
    pools: {
      // Populate with actual pool addresses from DeepBook
    },
    tokens: {
      sui: '0x2::sui::SUI',
      usdc: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      usdt: '0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN',
      deep: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP',
    },
  },
  testnet: {
    rpcUrl: 'https://fullnode.testnet.sui.io:443',
    deepbook: {
      package: '0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c',
      marginPackage: '0xd6a42f4df4db73d68cbeb52be66698d2fe6a9464f45ad113ca52b0c6ebd918b6',
    },
    pools: {
      // Testnet pool addresses
    },
    tokens: {
      sui: '0x2::sui::SUI',
      usdc: '0x...',  // Testnet USDC
      usdt: '0x...',  // Testnet USDT
      deep: '0x...',  // Testnet DEEP
    },
  },
  localnet: {
    rpcUrl: 'http://127.0.0.1:9000',
    deepbook: {
      package: '0x0',  // Will be set after local deployment
      marginPackage: '0x0',
    },
    pools: {},
    tokens: {
      sui: '0x2::sui::SUI',
      usdc: '0x0',
      usdt: '0x0',
      deep: '0x0',
    },
  },
};

// APEX package address (set after deployment)
export let APEX_PACKAGE = '0x0';

export function setApexPackage(address: string) {
  APEX_PACKAGE = address;
}
