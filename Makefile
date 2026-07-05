.PHONY: all inspect generate validate prepare execute configure verify vm-test clean

all:
	@echo "arch-deploy — Zenbook 14 Reinstall Pipeline"
	@echo ""
	@echo "Usage:"
	@echo "  make inspect           Run deep system scan"
	@echo "  make generate          Build profile from inspect data"
	@echo "  make validate          RO security audit from USB"
	@echo "  make prepare           ISO env setup (dry-run safe)"
	@echo "  make execute           Base install (DESTRUCTIVE)"
	@echo "  make configure         Post-install config"
	@echo "  make verify            Seal and verify"
	@echo "  make vm-test           Launch QEMU test VM"
	@echo "  make clean             Remove inspect output"
	@echo ""
	@echo "Always use --dry-run first:"
	@echo "  ./arch-deploy.sh --profile profiles/my-machine.yaml prepare --dry-run"

inspect:
	./stages/01-inspect.sh --output ./inspect-out

generate: inspect
	./stages/02-generate-profile.sh --inspect-dir ./inspect-out --out-dir ./profiles

validate:
	./stages/03-validate.sh --profile ./profiles/my-machine.yaml

prepare:
	./stages/04-prepare.sh --profile ./profiles/my-machine.yaml --dry-run

prepare-real:
	./stages/04-prepare.sh --profile ./profiles/my-machine.yaml

execute-dry:
	./stages/05-execute.sh --profile ./profiles/my-machine.yaml --dry-run

execute:
	./stages/05-execute.sh --profile ./profiles/my-machine.yaml

configure:
	./stages/06-configure.sh --profile ./profiles/my-machine.yaml

verify:
	./stages/07-verify.sh --profile ./profiles/my-machine.yaml

vm-test:
	./vm-test/run-qemu.sh

clean:
	rm -rf ./inspect-out ./inspect-*.tar.gz
