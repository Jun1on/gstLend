const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

// scale down amounts smaller for testing
const SCALE_DOWN = 0;
describe('Tests', () => {

  // USDC
  const PID = 0
  const DEC = 6
  const RICH_GUY        = "0x7c43a9c3b85619be2f7c0a4d676ecd373f63b73c"
  const USDC_WHALE      = "0x0fd6f65d35cf13ae51795036d0ae9af42f3cbcb4"
  const USDC_ADDRESS    = "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8"
  const gmdUSDC_ADDRESS = "0x3DB4B7DA67dd5aF61Cb9b3C70501B1BdB24b2C22"

  // ETH
  // const PID = 1
  // const DEC = 18
  // const RICH_GUY        = "0x7c43a9c3b85619be2f7c0a4d676ecd373f63b73c"
  // const USDC_WHALE      = "0xd665ac733ffc570e2f342cd9ba6d7536a5920910"
  // const USDC_ADDRESS    = "0x82af49447d8a07e3bd95bd0d56f35241523fbab1"
  // const gmdUSDC_ADDRESS = "0x1e95a37be8a17328fbf4b25b9ce3ce81e271beb3"

  // WBTC
  // const PID = 2
  // const DEC = 8
  // const RICH_GUY        = "0x3b7424d5cc87dc2b670f4c99540f7380de3d5880"
  // const USDC_WHALE      = "0x1b72bac3772050fdcaf468cce7e20deb3cb02d89"
  // const USDC_ADDRESS    = "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f"
  // const gmdUSDC_ADDRESS = "0x147FF11D9B9Ae284c271B2fAaE7068f4CA9BB619"

  // USDT (non standard)
  // const PID = 4
  // const DEC = 18
  // const RICH_GUY        = "0x9b64203878f24eb0cdf55c8c6fa7d08ba0cf77e5"
  // const USDC_WHALE      = "0xa507b355d6288a232ac692dad36af80ff1eba062"
  // const USDC_ADDRESS    = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9"
  // const gmdUSDC_ADDRESS = "0x34101Fe647ba02238256b5C5A58AeAa2e532A049"


  before(async () => {
    [owner, signer2, signer3, signer4, signer5] = await ethers.getSigners();


    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [RICH_GUY],
    });
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [USDC_WHALE],
    });
  
    rich = await ethers.getSigner(RICH_GUY);
    whale = await ethers.getSigner(USDC_WHALE);
    USDC = await ethers.getContractAt("contracts/GMDvault.sol:IERC20", USDC_ADDRESS);
    gmdUSDC = await ethers.getContractAt("contracts/GMDvault.sol:IERC20", gmdUSDC_ADDRESS);

    await USDC.connect(rich).transfer(whale.address, e("10000", DEC));
    await USDC.connect(whale).transfer(signer2.address, e("1000", DEC));
    await gmdUSDC.connect(whale).transfer(signer2.address, e("1000", 18));

  });
  beforeEach(async () => {
    GhaLendN = await ethers.getContractFactory("GHALendNoTimePass");
    USDCLendN = await GhaLendN.deploy(PID, 18 - DEC);
    await USDC.connect(whale).approve(USDCLendN.address, e("100000", DEC));
    await gmdUSDC.connect(whale).approve(USDCLendN.address, e("100000", 18));
    await USDC.connect(signer2).approve(USDCLendN.address, e("100000", DEC));
    await gmdUSDC.connect(signer2).approve(USDCLendN.address, e("100000", 18));

    GhaLend = await ethers.getContractFactory("GHALend");
    Lend = await GhaLend.deploy(PID, 18-DEC);
    await USDC.connect(whale).approve(Lend.address, e("100000", DEC));
    await gmdUSDC.connect(whale).approve(Lend.address, e("100000", 18));
    await USDC.connect(signer2).approve(Lend.address, e("100000", DEC));
    await gmdUSDC.connect(signer2).approve(Lend.address, e("100000", 18));
    });


    describe("ghaLend", function () {
      
      
        it("works with one account", async function () {
          // deposit 2 gmdUSDC
          await USDCLendN.connect(whale).depositGmd(e("2", 18))
          let gmdDeposits = await USDCLendN.gmdDeposits(whale.address)
          expect(gmdDeposits).to.equal(e("2", 18))
          // withdraw 1 gmdUSDC
          await USDCLendN.connect(whale).withdrawGmd(e("1", 18))
          gmdDeposits = await USDCLendN.gmdDeposits(whale.address)
          expect(gmdDeposits).to.equal(e("1", 18))

          // deposit 2 USDC
          await USDCLendN.connect(whale).deposit(e("2", DEC))
          let xdeposits = await USDCLendN.xdeposits(whale.address)
          expect(xdeposits).to.equal(e("2", 18))
          // withdraw 1 USDC
          await USDCLendN.connect(whale).withdraw(e("1", DEC))
          xdeposits = await USDCLendN.xdeposits(whale.address)
          expect(xdeposits).to.equal(e("1", 18))

          // borrow 0.8 USDC
          await USDCLendN.connect(whale).borrow(e("0.8", DEC))
          logBlock()
          let xborrows = await USDCLendN.xborrows(whale.address)
          expect(xborrows).to.equal(e("0.8", 18))
          
          // utilization ratio is 80%
          expect(await USDCLendN.totalBorrows()).to.equal(e("0.8", 18))
          expect(await USDCLendN.totalDeposits()).to.equal(e("1", 18))
          // borrow APR is 10%
          await expect(await USDCLendN.borrowAPR()).to.equal(a("0.1", 18))

          // borrow 0.05 USDC
          await USDCLendN.connect(whale).borrow(e("0.05", DEC))
          // borrowing 0.05 USDC fails
          await expect(USDCLendN.connect(whale).borrow(e("0.05", DEC))).to.be.revertedWith("GHALend: Insufficient collateral")

          // utilization ratio is 85% => borrow APR is 15%
          // borrow APR is now min(gmdUSDC APR, APR)
          logAPR()

          await USDCLendN.connect(whale).repay(e("0.8", DEC))

          // utilization ratio is 5% => borrow APR is 2.5%
          logAPR()

          console.log("TB",await USDCLendN.totalBorrows())
          // repay all
          await USDCLendN.connect(whale).repay(e("99999", DEC))

          // utilization ratio is 0% => borrow APR is 2%
          logAPR()

          logBlock()
          console.log("TB",await USDCLendN.totalBorrows())
          console.log("TxB",await USDCLendN.totalxBorrows())

          // zero borrows
          xborrows = await USDCLendN.xborrows(whale.address)
          expect(xborrows).to.equal(0)

          // treasury accrues fees
          console.log("Treasury fees: "+await USDC.balanceOf("0x52D16E8550785F3F1073632bC54dAa2e07e60C1c"))
        });
        it("deposit and withdraw max", async function () {
          let whaleUSDC = await USDC.balanceOf(whale.address)
          let whalegmdUSDC = await gmdUSDC.balanceOf(whale.address)
          // whale deposit 1 USDC
          await USDCLendN.connect(whale).deposit(e("1000", DEC))
          expect(await USDC.balanceOf(USDCLendN.address)).to.equal(e("1000", DEC))
          // deposit 100 gmdUSDC
          await USDCLendN.connect(signer2).depositGmd(e("100", 18))
          // 100*1.089351534411948181*0.8 = 87.14
          // borrow 87 USDC
          await USDCLendN.connect(signer2).borrow(e("87", DEC))
          await expect(USDCLendN.connect(signer2).borrow(e("1", DEC))).to.be.revertedWith("GHALend: Insufficient collateral")
          await expect(USDCLendN.connect(signer2).withdrawGmd(e("1", 18))).to.be.revertedWith("GHALend: Insufficient collateral")
          // check balances
          expect(await USDC.balanceOf(whale.address)).to.equal(whaleUSDC.sub(e("1000", DEC)))
          expect(await USDC.balanceOf(signer2.address)).to.equal(e("1087", DEC))
          expect(await gmdUSDC.balanceOf(signer2.address)).to.equal(e("900", 18))
          expect(await USDC.balanceOf(USDCLendN.address)).to.equal(e("913", DEC))
          expect(await gmdUSDC.balanceOf(USDCLendN.address)).to.equal(e("100", 18))
          // repay max, withdraw max
          await USDCLendN.connect(signer2).repay(e("999999999", DEC))
          await USDCLendN.connect(signer2).withdrawGmd(e("100", 18))
          await USDCLendN.connect(whale).withdraw(e("999999999", DEC))
          // check balances
          //expect(await USDC.balanceOf(whale.address)).to.equal(whaleUSDC)
          expect(await USDC.balanceOf(signer2.address)).to.equal(e("1000", DEC))
          expect(await gmdUSDC.balanceOf(signer2.address)).to.equal(e("1000", 18))
        });
        it("liquidates", async function () {
          let whaleUSDC = await USDC.balanceOf(whale.address)
          let whalegmdUSDC = await gmdUSDC.balanceOf(whale.address)
          console.log("   whale deposit 1000 USDC")
          await Lend.connect(whale).deposit(e("1000", DEC))
          console.log("   deposit 100 gmdUSDC")
          await Lend.connect(signer2).depositGmd(e("100", 18))
          // 100*1.089351534411948181*0.8 = 87.14
          console.log("   borrow 87 USDC")
          await Lend.connect(signer2).borrow(e("87", DEC))
          console.log("APR: "+d(await Lend.borrowAPR(),18))
          console.log("LTV:",d(await Lend.userLTV(signer2.address)))
          await time.increase(3600)
          console.log("LTV:",d(await Lend.userLTV(signer2.address)))
          // notice how LTV goes down
          // lets up the interest rate and try to get liquidated
          await expect(Lend.connect(whale).redeem(signer2.address, 0)).to.be.revertedWith("GHALend: too much redemption")
          console.log("   whale withdraw 900 USDC")
          await Lend.connect(whale).withdraw(e("900", DEC))
          console.log("APR: "+d(await Lend.borrowAPR(),18))
          console.log("   wait a year")
          await time.increase(3.154e+7)
          console.log("LTV:",d(await Lend.userLTV(signer2.address)))
          // compound to boost apr
          console.log("Treasury fees: ",d(await Lend.xdeposits("0x52D16E8550785F3F1073632bC54dAa2e07e60C1c")))
          console.log("TB",d(await Lend.totalBorrows()))
          await Lend.connect(signer2).repay(1)
          console.log("Treasury fees: ",d(await Lend.xdeposits("0x52D16E8550785F3F1073632bC54dAa2e07e60C1c")))
          console.log("TB",d(await Lend.totalBorrows()))
          // wait 10 years
          await time.increase(3.154e+7 * 10)
          console.log("LTV:",d(await Lend.userLTV(signer2.address)))
          // compound to boost apr
          await Lend.connect(whale).deposit(e("100", DEC))
          console.log("LTV:",d(await Lend.userLTV(signer2.address)))
          console.log("gD",d(await Lend.gmdDeposits(signer2.address)))
          console.log("TD",d(await Lend.totalDeposits()))
          console.log("xB",d(await Lend.xborrows(signer2.address)))
          console.log("TB",d(await Lend.totalBorrows()))
          await Lend.connect(whale).redeem(signer2.address, e("80", 6))
          console.log("LTV:",d(await Lend.userLTV(signer2.address)))

        });
        
        it("manual check", async function () {
          await logAll()
          let whaleUSDC = await USDC.balanceOf(whale.address)
          let whalegmdUSDC = await gmdUSDC.balanceOf(whale.address)
          console.log("   whale deposit 1000 USDC")
          await Lend.connect(whale).deposit(e("1000", DEC))
          console.log("   deposit 100 gmdUSDC")
          await Lend.connect(signer2).depositGmd(e("100", 18))
          // 100*1.089351534411948181*0.8 = 87.14
          console.log("   borrow 87 USDC")
          await Lend.connect(signer2).borrow(e("87", DEC))
          await logAll()
          console.log("   wait an hour")
          await time.increase(3600)
          await logAll()
          console.log("   whale withdraw 900 USDC")
          await Lend.connect(whale).withdraw(e("900", DEC))
          console.log("   wait a year")
          await time.increase(3.154e+7)
          await logAll()
          console.log("   repay 1 wei")
          await Lend.connect(signer2).repay(1)
          await logAll()
          await logExtra()
          console.log("   wait 10 years")
          await time.increase(3.154e+7 * 10)
          await logAll()
          await logExtra()
          console.log("   whale deposits 100 USDC")
          await Lend.connect(whale).deposit(e("100", DEC))
          await logAll()
          await logExtra()
          console.log("   whale liquidates")
          await Lend.connect(whale).redeem(signer2.address, e("5", DEC))
          await logAll()
          await logExtra()
          await expect(Lend.connect(whale).redeem(signer2.address, e("100", DEC))).to.be.revertedWith("GHALend: too much redemption")
        });

        

    });
})

async function logAll() {
  console.log("LTV:",d(await Lend.userLTV(signer2.address)))
  console.log("I have ",d(await Lend.gmdDeposits(signer2.address)),"GMD deposited = $"+d(await Lend.gmdDeposits(signer2.address))*(await Lend.usdPerGmdUSDC())/1e18)
  console.log("I have ",d(await Lend.xborrows(signer2.address)),"xborrows = $"+d(await Lend.xborrows(signer2.address))*(await Lend.usdPerxBorrow())/1e18)
  console.log("--GLOBAL STATS--")
  console.log("APR: "+d(await Lend.borrowAPR(),18))
  console.log("Total USDC Deposited:",d(await Lend.totalDeposits()))
  console.log("Total USDC Borrowed:",d(await Lend.totalBorrows()))
  console.log("Protocol owns:",d(await USDC.balanceOf(Lend.address), 6),"USDC")
  console.log("Protocol owns:",d(await gmdUSDC.balanceOf(Lend.address)),"gmdUSDC")
}
async function logExtra() {
  console.log("--extra--")
  console.log("whale has", d(await Lend.xdeposits(whale.address)),"xdeposits")
  console.log("Treasury fees:",d(await Lend.xdeposits("0x52D16E8550785F3F1073632bC54dAa2e07e60C1c")))
  console.log("total", d(await Lend.totalxDeposits()),"xdeposits")
  console.log("usdPerxDeposit:", d(await Lend.usdPerxDeposit(),18+SCALE_DOWN))
  console.log("usdPerxBorrow:", d(await Lend.usdPerxBorrow(),18+SCALE_DOWN))
}

async function logAPR() {
  console.log("APR: "+d(await USDCLendN.borrowAPR(),18))
}

function a(amount, decimals) {
  return ethers.utils.parseUnits(amount, decimals)
}
function e(amount, decimals) {
  return ethers.utils.parseUnits(amount, decimals-SCALE_DOWN)
}
function d(amount, decimals = 18) {
  return amount/10**(decimals-SCALE_DOWN);
}
async function logBlock() {
  console.log("block #"+await time.latestBlock());
}
