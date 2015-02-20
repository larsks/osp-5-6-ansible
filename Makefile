DOCS = README.md

all: $(DOCS)

README.md: osp-5-6-ha-upgrade.yaml
	sh makedoc.sh $^ > $@ || rm -f $@

