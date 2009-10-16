EXE      = affine
GHC      = ghc
EXAMPLES = examples

default: Setup dist/setup-config
	./Setup build
	cp dist/build/affine/affine .

dist/setup-config config: Setup affine.cabal
	./Setup configure --flags="$(FLAGS)"

Setup: Setup.hs
	$(GHC) -o $@ --make $<

$(EXE): default

test tests: $(EXE)
	@for i in $(EXAMPLES)/ex*.aff; do \
	  $(EXAMPLES)/run-test.sh $(EXE) "$$i"; \
	done
	@for i in $(EXAMPLES)/*.in; do \
	  out="`echo $$i | sed 's/\.in$$/.out/'`"; \
	  aff="`echo $$i | sed 's/-[[:digit:]]*\.in$$/.aff/'`"; \
	  echo "$$i"; \
	  ./$(EXE) "$$aff" < "$$i" | diff "$$out" - ; \
	done

examples: $(EXE)
	@for i in $(EXAMPLES)/ex*.aff; do \
	  echo "$$i"; \
	  head -1 "$$i"; \
	  ./$(EXE) "$$i"; \
	  echo; \
	done
	@for i in $(EXAMPLES)/*.in; do \
	  out="`echo $$i | sed 's/\.in$$/.out/'`"; \
	  aff="`echo $$i | sed 's/-[[:digit:]]*\.in$$/.aff/'`"; \
	  echo "$$i"; \
	  ./$(EXE) "$$aff" < "$$i"; \
	done

clean:
	$(RM) *.hi *.o $(EXE) $(TARBALL) Setup
	$(RM) -Rf $(DISTDIR) dist


VERSION = 0.10.2
DISTDIR = affine-contracts-$(VERSION)
TARBALL = $(DISTDIR).tar.gz

dist: $(TARBALL)

$(TARBALL):
	$(RM) -Rf $(TARBALL) $(DISTDIR)
	svn export . $(DISTDIR)
	tar czf $(TARBALL) $(DISTDIR)
	$(RM) -Rf $(DISTDIR)
	chmod a+r $(TARBALL)
