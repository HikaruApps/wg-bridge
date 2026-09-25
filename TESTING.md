# Testing notes

Run `bash -n wg-bridge-manager.sh` and `printf '0\n' | sudo bash wg-bridge-manager.sh` for a read-only menu smoke test. Before a release test creation on expendable ENTRY and EXIT VPSs with provider-console access, separate default routes, WARP and RemnaNode if relevant. Confirm old `wg-shadow`, table 177 and mark 375 remain intact through install, start, stop and reboot. Verify table isolation, both egress IPs, local firewall, external firewall, UDP, SSH and Psiphon routing. Do not claim production readiness before actual integration tests.
