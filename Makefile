.PHONY: test clean

test:
	$(MAKE) -C test all

clean:
	$(MAKE) -C test clean
