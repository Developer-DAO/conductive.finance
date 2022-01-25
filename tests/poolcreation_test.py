from distutils.log import error
import pytest
from brownie import (
    convert,
    ZERO_ADDRESS,
    accounts,
    chain,
    rpc,
    reverts,
    web3,
    Contract,
)
from brownie_tokens import MintableForkToken


def test_trainid_is_validatedbyby_uniswap_registry(yMarkt, uniswap):
    USDCWETH = "0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8"
    USDC = "0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48"
    WETH = "0xC02AAA39B223FE8D0A0E5C4F27EAD9083C756CC2"
    unipool = str(uniswap.getPool(USDC, WETH, "3000"))
    yresultunipool = str(yMarkt.isValidPool(USDC, WETH, "3000"))
    assert yresultunipool == unipool
    ###  ValueError: invalid literal for int() with base 16: '' - ganache-cli:


def test_becomes_valid_pool(yMarkt, uniswap):
    STASIS = "0xdb25f211ab05b1c97d595516f45794528a807ad8"
    YFI = "0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e"

    assert yMarkt.isValidPool(STASIS, YFI, "3000") == ZERO_ADDRESS

    cycle_freq = 306  # blocks
    min_cycles = 100
    budget_slice = 2  # %2 distribute per cycle
    price_memory = 10  # 'days ago memory'
    minbag = 1

    assert yMarkt.createTrain(
        STASIS,
        YFI,
        3000,
        ZERO_ADDRESS,
        cycle_freq,
        min_cycles * cycle_freq,
        budget_slice,
        price_memory,
        minbag,
    )

    assert yMarkt.isValidPool(STASIS, YFI, "3000") != ZERO_ADDRESS

    ###  ValueError: invalid literal for int() with base 16: '' - ganache-cli:


def test_create_train_returns_true(yMarkt, addrzero, uniswap):
    cycle_freq = 306  # blocks
    min_cycles = 100
    budget_slice = 2  # %2 distribute per cycle
    price_memory = 10  # 'days ago memory'
    USDCWETH = "0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8"
    USDC = "0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48"
    WETH = "0xC02AAA39B223FE8D0A0E5C4F27EAD9083C756CC2"
    minbag = 10
    # arguments: pool, yvault, cycelFreq, minDistance, budgetSlicer, upperRewardBound
    assert yMarkt.createTrain(
        USDC,
        WETH,
        3000,
        addrzero,
        cycle_freq,
        min_cycles * cycle_freq,
        budget_slice,
        price_memory,
        minbag,
    )
    train_1 = yMarkt.getTrain(USDCWETH)
    assert yMarkt.isValidPool(USDC, WETH, "3000") != ZERO_ADDRESS
    assert train_1[0][0] == accounts[0]


def test_creates_ticket(yMarkt):
    train = "0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8"
    previous_number_of_passengers = yMarkt.getTrain(train)[2]
    price = 9001
    bagsize = 100
    previous_tickets_onprice = len(yMarkt.getTicketsByPrice(train, price))
    previous_inCustody = yMarkt.getTrain(train)[3]
    # usdcrich = "0x2A549b4AF9Ec39B03142DA6dC32221fC390B5533"

    USDCtoken = MintableForkToken("0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48")
    USDCtoken.transfer(
        accounts[0], USDCtoken.balanceOf(accounts[-1]), {"from": accounts[-1]}
    )

    chain.mine(2)
    USDCtoken.approve(
        yMarkt.address,
        USDCtoken.balanceOf(accounts[0]),
        {"from": accounts[0]},
    )
    chain.mine(1)

    ticket = yMarkt.createTicket(
        100,
        price,
        "0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8",
        100,
        {"from": accounts[0]},
    )

    assert ticket
    assert yMarkt.getTrain(train)[4] == previous_number_of_passengers + 1
    assert len(yMarkt.getTicketsByPrice(train, price)) == previous_tickets_onprice + 1
    assert yMarkt.getTrain(train)[3] == previous_inCustody + bagsize

    # errMsg = "0x65ba9ff1"
    ##errMsg = web3.keccak(text="MinDepositRequired()")[:4].hex()
    # with brownie.reverts(
    #     "typed error: 0x65ba9ff1000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000008"
    # ):
    #     x =yMarkt.createTicket(100, price, "0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8", 8)


def test_burns_ticket(yMarkt):
    train_prev = yMarkt.getTrain(
        "0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8", {"from": accounts[0]}
    )

    chain.mine(3)
    ticket = yMarkt.getTicket(accounts[0], "0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8")
    chain.mine(1)
    assert ticket[0] > 0 and ticket[1] < chain.height
    yMarkt.burnTicket("0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8")

    train_after = yMarkt.getTrain(
        "0x8AD599C3A0FF1DE082011EFDDC58F1908EB6E6D8", {"from": accounts[0]}
    )
    assert train_prev[3] > train_after[3]
    assert train_prev[4] == train_after[4] + 1
