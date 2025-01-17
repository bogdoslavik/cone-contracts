import {ethers, web3} from "hardhat";
import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import {Logger} from "tslog";
import logSettings from "../../log_settings";
import {BigNumber, ContractFactory, utils} from "ethers";
import {Libraries} from "hardhat-deploy/dist/types";
import {
  BribeFactory,
  Cone,
  ConeFactory,
  ConeMinter,
  ConeRouter01,
  ConeVoter,
  Controller,
  GaugeFactory,
  Token,
  Ve,
  VeDist
} from "../../typechain";
import {Misc} from "../Misc";
import {CoreAddresses} from "./CoreAddresses";

const log: Logger = new Logger(logSettings);

const libraries = new Map<string, string>([
  ['Ve', 'VeLogo']
]);

export class Deploy {

  // ************ CONTRACT CONNECTION **************************

  public static async deployContract<T extends ContractFactory>(
    signer: SignerWithAddress,
    name: string,
    // tslint:disable-next-line:no-any
    ...args: any[]
  ) {
    log.info(`Deploying ${name}`);
    log.info("Account balance: " + utils.formatUnits(await signer.getBalance(), 18));

    const gasPrice = await web3.eth.getGasPrice();
    log.info("Gas price: " + gasPrice);
    const lib: string | undefined = libraries.get(name);
    let _factory;
    if (lib) {
      log.info('DEPLOY LIBRARY', lib, 'for', name);
      const libAddress = (await Deploy.deployContract(signer, lib)).address;
      const librariesObj: Libraries = {};
      librariesObj[lib] = libAddress;
      _factory = (await ethers.getContractFactory(
        name,
        {
          signer,
          libraries: librariesObj
        }
      )) as T;
    } else {
      _factory = (await ethers.getContractFactory(
        name,
        signer
      )) as T;
    }
    const instance = await _factory.deploy(...args);
    log.info('Deploy tx:', instance.deployTransaction.hash);
    await instance.deployed();

    const receipt = await ethers.provider.getTransactionReceipt(instance.deployTransaction.hash);
    log.info('Receipt', receipt.contractAddress)
    return _factory.attach(receipt.contractAddress);
  }

  public static async deployCone(signer: SignerWithAddress) {
    return (await Deploy.deployContract(signer, 'Cone')) as Cone;
  }

  public static async deployToken(signer: SignerWithAddress, name: string, symbol: string, decimal: number) {
    return (await Deploy.deployContract(signer, 'Token', name, symbol, decimal, signer.address)) as Token;
  }

  public static async deployGaugeFactory(signer: SignerWithAddress) {
    return (await Deploy.deployContract(signer, 'GaugeFactory')) as GaugeFactory;
  }

  public static async deployBribeFactory(signer: SignerWithAddress) {
    return (await Deploy.deployContract(signer, 'BribeFactory')) as BribeFactory;
  }

  public static async deployConeFactory(signer: SignerWithAddress) {
    return (await Deploy.deployContract(signer, 'ConeFactory')) as ConeFactory;
  }

  public static async deployConeRouter01(
    signer: SignerWithAddress,
    factory: string,
    networkToken: string,
  ) {
    return (await Deploy.deployContract(signer, 'ConeRouter01', factory, networkToken)) as ConeRouter01;
  }

  public static async deployVe(signer: SignerWithAddress, token: string, controller: string) {
    return (await Deploy.deployContract(signer, 'Ve', token, controller)) as Ve;
  }

  public static async deployVeDist(signer: SignerWithAddress, ve: string) {
    return (await Deploy.deployContract(signer, 'VeDist', ve)) as VeDist;
  }

  public static async deployConeVoter(
    signer: SignerWithAddress,
    ve: string,
    factory: string,
    gauges: string,
    bribes: string,
  ) {
    return (await Deploy.deployContract(
      signer,
      'ConeVoter',
      ve,
      factory,
      gauges,
      bribes,
    )) as ConeVoter;
  }

  public static async deployConeMinter(
    signer: SignerWithAddress,
    ve: string,
    controller: string,
  ) {
    return (await Deploy.deployContract(
      signer,
      'ConeMinter',
      ve,
      controller
    )) as ConeMinter;
  }

  public static async deployCore(
    signer: SignerWithAddress,
    networkToken: string,
    voterTokens: string[],
    minterClaimants: string[],
    minterClaimantsAmounts: BigNumber[],
    minterSum: BigNumber,
    warmingUpPeriod = 2
  ) {
    const [baseFactory, router] = await Deploy.deployDex(signer, networkToken);

    const [
      controller,
      token,
      gaugesFactory,
      bribesFactory,
      ve,
      veDist,
      voter,
      minter,
    ] = await Deploy.deployConeSystem(
      signer,
      voterTokens,
      minterClaimants,
      minterClaimantsAmounts,
      minterSum,
      baseFactory.address,
      warmingUpPeriod,
    );

    return new CoreAddresses(
      token as Cone,
      gaugesFactory as GaugeFactory,
      bribesFactory as BribeFactory,
      baseFactory as ConeFactory,
      router as ConeRouter01,
      ve as Ve,
      veDist as VeDist,
      voter as ConeVoter,
      minter as ConeMinter,
      controller as Controller,
    );
  }


  public static async deployDex(
    signer: SignerWithAddress,
    networkToken: string,
  ) {
    const baseFactory = await Deploy.deployConeFactory(signer);
    const router = await Deploy.deployConeRouter01(signer, baseFactory.address, networkToken);

    return [baseFactory, router];
  }

  public static async deployConeSystem(
    signer: SignerWithAddress,
    voterTokens: string[],
    minterClaimants: string[],
    minterClaimantsAmounts: BigNumber[],
    minterSum: BigNumber,
    baseFactory: string,
    warmingUpPeriod: number,
  ) {
    const controller = await Deploy.deployContract(signer, 'Controller') as Controller;
    await Misc.delay(10_000);
    const token = await Deploy.deployCone(signer);
    await Misc.delay(10_000);
    const ve = await Deploy.deployVe(signer, token.address, controller.address);
    await Misc.delay(10_000);
    const gaugesFactory = await Deploy.deployGaugeFactory(signer);
    await Misc.delay(10_000);
    const bribesFactory = await Deploy.deployBribeFactory(signer);
    await Misc.delay(10_000);


    const veDist = await Deploy.deployVeDist(signer, ve.address);
    await Misc.delay(10_000);
    const voter = await Deploy.deployConeVoter(signer, ve.address, baseFactory, gaugesFactory.address, bribesFactory.address);
    await Misc.delay(10_000);
    const minter = await Deploy.deployConeMinter(signer, ve.address, controller.address);
    await Misc.delay(10_000);

    await Misc.runAndWait(() => token.setMinter(minter.address));
    await Misc.runAndWait(() => veDist.setDepositor(minter.address));
    await Misc.runAndWait(() => controller.setVeDist(veDist.address));
    await Misc.runAndWait(() => controller.setVoter(voter.address));

    await Misc.runAndWait(() => voter.initialize(voterTokens, minter.address));
    await Misc.runAndWait(() => minter.initialize(
      minterClaimants,
      minterClaimantsAmounts,
      minterSum,
      warmingUpPeriod
    ));

    return [
      controller,
      token,
      gaugesFactory,
      bribesFactory,
      ve,
      veDist,
      voter,
      minter,
    ];
  }

}
