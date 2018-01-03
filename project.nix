{ pkgs, haskellPackages, }:

let
  pname = "nix-binary-cache";

  binaryLibrary = if builtins.getEnv "USE_CEREAL" != ""
                  then "cereal" else "binary";

  version = "0.0.1";
  # Haskell packages the library depends on (in addition to above). We
  # use names here because for some reason some of these are null in
  # the haskell package set, but still work as dependencies...
  dependencies = [
    "aeson"
    "attoparsec"
    "base"
    binaryLibrary
    "bytestring"
    "bytestring-conversion"
    "base64-bytestring"
    "classy-prelude"
    "directory"
    "filepath"
    "http-client"
    "http-client-openssl"
    "http-client-tls"
    "http-media"
    "http-types"
    "lifted-async"
    "lifted-base"
    "lzma"
    "lucid"
    "mtl"
    "parsec"
    "pcre-heavy"
    "process"
    "process-extras"
    "servant-client"
    "servant-lucid"
    "servant-server"
    "servant"
    "sqlite-simple"
    "text"
    "transformers"
    "unordered-containers"
    "vector"
    "wai"
    "wai-extra"
    "warp"
    "zlib"
  ];

  # Haskell packages the tests depend on (in addition to above).
  testDependencies = [
    "QuickCheck"
    "hspec"
    "microtimer"
    "random-strings"
  ];

  # Names of extensions that the library uses.
  extensions = [
    "ConstraintKinds"
    "CPP"
    "DataKinds"
    "DeriveGeneric"
    "FlexibleContexts"
    "FlexibleInstances"
    "GADTs"
    "GeneralizedNewtypeDeriving"
    "LambdaCase"
    "MultiParamTypeClasses"
    "NoImplicitPrelude"
    "OverloadedStrings"
    "QuasiQuotes"
    "RecordWildCards"
    "ScopedTypeVariables"
    "TypeFamilies"
    "TypeOperators"
    "TypeSynonymInstances"
    "ViewPatterns"
  ];

  # Derivations needed to use in the nix shell.
  shellRequires = with pkgs; [
    curl
    nix.out
    less
    nmap
    silver-searcher
    which
  ];

  # Given a list of strings, look all of them up in the haskell package set.
  toHaskellPkgs = map (pname: haskellPackages."${pname}");

  inherit (builtins) compareVersions;
  inherit (pkgs.lib) filter concatStringsSep isDerivation optional;
  joinLines = builtins.concatStringsSep "\n";
  joinCommas = builtins.concatStringsSep ", ";
  joinSpaces = builtins.concatStringsSep " ";

  # Options for ghc when both testing and building the library.
  ghc-options = [
    # Warn on everything, including tabs.
    "-Wall" "-fwarn-tabs"
    # Don't warn on unused do-binding.
    "-fno-warn-unused-do-bind"
    # Don't warn on name shadowing. This is why lexical scoping exists...
    "-fno-warn-name-shadowing"
    # Enable threading.
    "-threaded" "-rtsopts" "-with-rtsopts=-N"
  ];

  # Options for ghc when just building the library.
  ghc-build-options = ghc-options ++ [
    # Enable optimization
    "-O3"
    # Turn warnings into errors.
    # "-Werror"
  ];

  # Options for ghc when just testing.
  ghc-test-options = ghc-options ++ [
    "-fno-warn-orphans"
  ];

  # Inspect the servant derivation to see if it's an old version; if
  # so define a cpp flag.
  cpp-options = optional
    (compareVersions haskellPackages.servant.version "0.7" < 0)
    "-DOLD_SERVANT" ++
    optional (binaryLibrary == "cereal") "-DUSE_CEREAL";

  # .ghci file text.
  dotGhci = pkgs.writeText "${pname}.ghci" (joinLines (
    map (ext: ":set -X${ext}") extensions ++
    [
      ":set prompt \"λ> \""
      "import Data.Text (Text)"
      "import qualified Servant"
      "import qualified Data.Text as T"
      "import qualified Data.Text.Encoding as T"
      "import qualified Data.HashMap.Strict as H"
      "import ClassyPrelude"
      "import Control.Concurrent.Async.Lifted"
      ""
    ]
  ));

  # Cabal file text.
  cabalFile = pkgs.writeText "${pname}.cabal" ''
    -- This cabal file is generated by a nix expression (see project.nix).
    -- It is not meant to be modified by hand.
    name:                ${pname}
    version:             ${version}
    license:             MIT
    license-file:        LICENSE
    author:              Allen Nelson
    maintainer:          ithinkican@gmail.com
    build-type:          Simple
    cabal-version:       >=1.10
    data-files:            sql/tables.sql

    -- Define the executable
    executable nix-client
      main-is:             Nix/Cache/Client/Main.hs
      build-depends:       ${joinCommas dependencies}
      hs-source-dirs:      src
      default-language:    Haskell2010
      default-extensions:  ${joinCommas extensions}
      ghc-options:         -O3 ${joinSpaces ghc-build-options}
      cpp-options:         ${joinSpaces cpp-options}

    ${if false then "" else ''
    executable ref-cache
      main-is:             Nix/ReferenceCache.hs
      build-depends:       ${joinCommas dependencies}
      hs-source-dirs:      src
      default-language:    Haskell2010
      default-extensions:  ${joinCommas extensions}
      ghc-options:         -O3 ${joinSpaces ghc-build-options}
      cpp-options:         ${joinSpaces cpp-options}
    ''}

    ${if true then "" else ''
    executable nix-server
      main-is:             Server.hs
      build-depends:       ${joinCommas dependencies}
      hs-source-dirs:      src
      default-language:    Haskell2010
      default-extensions:  ${joinCommas extensions}
      ghc-options:         -O3 ${joinSpaces ghc-build-options}
    ''}

    -- Define a unit test suite
    test-suite unit-tests
      type:                exitcode-stdio-1.0
      hs-source-dirs:      src, tests
      main-is:             Unit.hs
      build-depends:       ${joinCommas (dependencies ++ testDependencies)}
      ghc-options:         ${joinSpaces ghc-test-options}
      cpp-options:         -DUNIT_TESTS ${joinSpaces cpp-options}
      default-language:    Haskell2010
      default-extensions:  ${joinCommas extensions}
  '';
in

haskellPackages.mkDerivation rec {
  inherit pname version;
  src = let
    inherit (builtins) filterSource all match;
    # It'd be nice to make this a whitelist, but filterSource is kind
    # of terrible.
    blacklist = map (r: "^${r}$") [
      "${pname}\\.cabal" "init_db\\.sh" ".*\\.nix" "dist"
      "\\.git" "#.*" "\\.#.*" ".*~" "\\.ghci" "\\.gitignore"
    ];
    check = path: _:
      all (regex: match regex (baseNameOf path) == null) blacklist;
  in filterSource check ./.;
  isExecutable = true;
  buildTools = [haskellPackages.cabal-install];
  testHaskellDepends = toHaskellPkgs testDependencies;
  testDepends = shellRequires;
  checkPhase = ''
    export HOME=$TMPDIR USER=$(whoami)
    dist/build/unit-tests/unit-tests
  '';
  libraryHaskellDepends = toHaskellPkgs dependencies;
  executableHaskellDepends = toHaskellPkgs dependencies;
  preConfigure = ''
    cp -f ${cabalFile} ${pname}.cabal
  '';
  shellHook = ''
    export CURL_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    # Make sure we're in the project directory, and do initialization.
    if [[ -e project.nix ]] && grep -q ${pname} project.nix; then
      PROJECT_DIR=$PWD
      # Alias for entering REPL for unit tests.
      alias testr='(cd $PROJECT_DIR && cabal repl unit-tests)'

      # Define a function which uses ghci to run unit tests.
      runtests() ( cd $PROJECT_DIR && echo ':main' | cabal repl unit-tests; )

      cp -f ${dotGhci} .ghci
      eval "${preConfigure}"
      cabal clean
      cabal configure --enable-tests
    fi
  '';
  description = "A web server";
  license = pkgs.lib.licenses.unfree;
}
