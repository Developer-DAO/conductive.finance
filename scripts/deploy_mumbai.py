from brownie import accounts, Conductive, TrainSpotting, Contract, chain, convert, rpc
import time


def main():
    mumbaiA = accounts.load("mumbai1")
    print("using account: {} - {}".format(mumbaiA.address, mumbaiA.balance))
    spotter = mumbaiA.deploy(
        TrainSpotting,
        "0x001B3B4d0F3714Ca98ba10F6042DaEbF0B1B7b6F",  # "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063"
        "0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506",
        publish_source=True,
    )
    print("Deployed TrainSpotting contract: ", spotter.address)
    time.sleep(3)
    conductive = mumbaiA.deploy(
        Conductive,
        "0xc35DADB65012eC5796536bD9864eD8773aBc74C4",
        spotter.address,
        publish_source=True,
    )
    print("Deployed Conductive contract: ", conductive.address)
