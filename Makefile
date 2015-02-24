DOCS = osp-5-6-ha-upgrade.md

all: $(DOCS)

osp-5-6-ha-upgrade.md: osp-5-6-ha-upgrade.yaml
	sh makedoc.sh $^ > $@ || rm -f $@

