import logicTest from './LogicTest';
import { vpnArchTest } from './VpnArchTest';

export default function testsuite() {
  logicTest();
  vpnArchTest();
}
