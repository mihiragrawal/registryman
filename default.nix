{
  pkgs ? import (fetchTarball {
        url = https://github.com/NixOS/nixpkgs/archive/99c46c5bb5ab0e74a94945fe9222132757667d17.tar.gz;
        sha256 = "0dhxl001a9n6hvbrdcp4bxx5whd54jyamszskknkmy65d5gbnqxd";
  }) {},
  registryman-git-rev ? "",
  registryman-git-ref ? "",
  registryman-git-url ? "git@github.com:origoss/registryman.git",
  local-vendor-sha256 ? "sha256-0jHxfijHcQKD+DwsBdlW98xB6DfcmDqr4P7sQ3nuVV4=",
  git-vendor-sha256 ? "0gcxhzi24ali7kn9433igmzkw36yf7svvgnvv2jc7xsfhg165p63",
  registryman-from ? "local",
}:

assert registryman-from == "local" || registryman-from == "git";
assert registryman-from == "git" -> registryman-git-rev != "";
assert registryman-from == "git" -> registryman-git-url != "";

let
  controller-tools-config = {
    version = "0.9.2";
    sha256 = "sha256-fMLydjdL9GCSX2rf7ORW1RhZJpjA0hyeK40AwKTkrxg=";
    vendorSha256 = "sha256-6luowQB/j8ipHSuWMHia8SdacienDzpV8g2JH3k0W80=";
  };

  code-generator-config = {
    version = "0.24.3";
    sha256 = "sha256-HZLKCP8dHOG8o2UZrEGapy79FbFpXpjats6hQrQL/L8=";
    vendorSha256 = "sha256-p+dPvG4U3znbFZThukf+/uwgpGCos0CQz+q3P8eUtTw=";
  };

  registryman-local-source = pkgs.runCommand "registryman-local-source" {
    src = pkgs.nix-gitignore.gitignoreSource [
      ".git"
      "*.nix"
      "rm-dev.sh"
      "rm-git.sh"
      "docker-build.sh"
      "update-code.sh"
      "result"
      "generated-code"
      "testauto"
    ] ./.;
    nativeBuildInputs = [ pkgs.cpio ];
  } ''
    mkdir -p $out
    cp -a $src/* $out/
  '';

  registryman-vendor = registryman-src: sha256:
    pkgs.runCommand "registryman-local-vendor" {
      nativeBuildInputs = [ pkgs.go pkgs.cacert pkgs.git ];
      impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars ++ [
        "GIT_PROXY_COMMAND" "SOCKS_SERVER"
      ];
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = sha256;
    } ''
       mkdir -p $out
       mkdir -p $TMPDIR/tmp
       mkdir -p $TMPDIR/gomodules
       export GOMODCACHE=$TMPDIR/gomodules
       cp -a ${registryman-src}/* $TMPDIR/tmp
       chmod a+w $TMPDIR/tmp/go.mod
       chmod a+w $TMPDIR/tmp/go.sum
       cd tmp
       go mod vendor
       ls -l $TMPDIR/gomodules
       mv vendor/* $out
    '';

  registryman-local-vendor = registryman-vendor registryman-local-source local-vendor-sha256;

  registryman-local-generated = pkgs.runCommand "registryman-local-generated" {
  } ''
      mkdir $out
      cp -a ${registryman-local-source}/* $TMPDIR
      chmod a+rw -R $TMPDIR
      cp -a ${generated-code}/* $TMPDIR/pkg/apis/registryman/v1alpha1/
      cp -a $TMPDIR/* $out
    '';

  registryman = registryman-vendor:
    pkgs.runCommand "registryman-local" {
      buildInputs = [ pkgs.go pkgs.removeReferencesTo ];
      disallowedReferences = [ pkgs.go ];
    } ''
       mkdir -p $out/bin
       mkdir -p $TMPDIR/go/src/github.com/kubermatic-labs/registryman
       mkdir -p $TMPDIR/gocache
       export GOCACHE=$TMPDIR/gocache
       cp -a ${registryman-generated}/* $TMPDIR/go/src/github.com/kubermatic-labs/registryman
       ln -s ${registryman-vendor} $TMPDIR/go/src/github.com/kubermatic-labs/registryman/vendor
       cd $TMPDIR/go/src/github.com/kubermatic-labs/registryman
       export GOPATH=$TMPDIR/go
       export CGO_ENABLED=0
       go build -tags "exclude_graphdriver_devicemapper exclude_graphdriver_btrfs containers_image_openpgp" -ldflags="-s -w"
       remove-references-to -t ${pkgs.go} $TMPDIR/go/src/github.com/kubermatic-labs/registryman/registryman
       mv $TMPDIR/go/src/github.com/kubermatic-labs/registryman/registryman $out/bin
   '';

  registryman-git-source = fetchGit {
      url = registryman-git-url;
      ref = registryman-git-ref;
      rev = registryman-git-rev;
    };

  registryman-source = if registryman-from == "local" then registryman-local-source
    else registryman-git-source;

  registryman-git-vendor = registryman-vendor registryman-git-source git-vendor-sha256;

  registryman-generated = if registryman-from == "local" then registryman-local-generated
    else registryman-git-source;

  registryman-built = if registryman-from == "local" then
    registryman registryman-local-vendor else
      registryman registryman-git-vendor;

  registryman-kustomization-yaml = pkgs.writeTextFile {
    name = "registryman-kustomization-yaml";
    destination = "/kustomization.yaml";
    text = builtins.toJSON {
      apiVersion = "kustomize.config.k8s.io/v1beta1";
      kind = "Kustomization";
      namespace = "registryman";
      resources = [
        "registryman-namespace.yaml"
        "registryman-ca-certificate.yaml"
        "registryman-cert-issuer.yaml"
        "registryman-webhook-certificate.yaml"
        "registryman-webhook-serviceaccount.yaml"
        "registryman-serviceaccount.yaml"
        "registryman-deployment.yaml"
        "registryman-webhook-deployment.yaml"
        "registryman-webhook-clusterrole.yaml"
        "registryman-webhook-clusterrolebinding.yaml"
        "registryman-clusterrole.yaml"
        "registryman-clusterrolebinding.yaml"
        "registryman-webhook-vwc.yaml"
        "registryman-webhook-service.yaml"
      ];
      images = [
        {
          name = "registryman";
          newName = "registryman";
          newTag = image-tag;
        }
      ];
    };
  };

  registryman-kustomization-yaml-verbose = pkgs.writeTextFile {
    name = "registryman-kustomization-yaml";
    destination = "/kustomization.yaml";
    text = builtins.toJSON {
      apiVersion = "kustomize.config.k8s.io/v1beta1";
      kind = "Kustomization";
      namespace = "registryman";
      resources = [
        "registryman-namespace.yaml"
        "registryman-ca-certificate.yaml"
        "registryman-cert-issuer.yaml"
        "registryman-webhook-certificate.yaml"
        "registryman-webhook-serviceaccount.yaml"
        "registryman-serviceaccount.yaml"
        "registryman-webhook-deployment.yaml"
        "registryman-deployment.yaml"
        "registryman-webhook-clusterrole.yaml"
        "registryman-webhook-clusterrolebinding.yaml"
        "registryman-clusterrole.yaml"
        "registryman-clusterrolebinding.yaml"
        "registryman-webhook-vwc.yaml"
        "registryman-webhook-service.yaml"
      ];
      images = [
        {
          name = "registryman";
          newName = "registryman";
          newTag = image-tag;
        }
      ];
      patchesStrategicMerge = [
        "registryman-webhook-deployment-verbose-patch.yaml"
        "registryman-deployment-verbose-patch.yaml"
      ];
    };
  };

  registryman-deployment-manifests = pkgs.runCommand "registryman-deployment-manifests" {
    src = (builtins.toString registryman-source) + "/deploy";
  } ''
      mkdir -p $out
      cp -a ${registryman-kustomization-yaml}/kustomization.yaml $out/kustomization.yaml
      cp -a $src/registryman-namespace.yaml $out
      cp -a $src/registryman-ca-certificate.yaml $out
      cp -a $src/registryman-cert-issuer.yaml $out
      cp -a $src/registryman-webhook-certificate.yaml $out
      cp -a $src/registryman-webhook-serviceaccount.yaml $out
      cp -a $src/registryman-serviceaccount.yaml $out
      cp -a $src/registryman-webhook-deployment.yaml $out
      cp -a $src/registryman-deployment.yaml $out
      cp -a $src/registryman-clusterrole.yaml $out
      cp -a $src/registryman-clusterrolebinding.yaml $out
      cp -a $src/registryman-webhook-clusterrole.yaml $out
      cp -a $src/registryman-webhook-clusterrolebinding.yaml $out
      cp -a $src/registryman-webhook-vwc.yaml $out
      cp -a $src/registryman-webhook-service.yaml $out
    '';

  registryman-deployment-manifests-verbose = pkgs.runCommand "registryman-deployment-manifests" {
    src = (builtins.toString registryman-source) + "/deploy";
  } ''
      mkdir -p $out
      cp -a ${registryman-kustomization-yaml-verbose}/kustomization.yaml $out/kustomization.yaml
      cp -a $src/registryman-namespace.yaml $out
      cp -a $src/registryman-ca-certificate.yaml $out
      cp -a $src/registryman-cert-issuer.yaml $out
      cp -a $src/registryman-webhook-certificate.yaml $out
      cp -a $src/registryman-webhook-serviceaccount.yaml $out
      cp -a $src/registryman-serviceaccount.yaml $out
      cp -a $src/registryman-webhook-deployment.yaml $out
      cp -a $src/registryman-deployment.yaml $out
      cp -a $src/registryman-webhook-clusterrole.yaml $out
      cp -a $src/registryman-webhook-clusterrolebinding.yaml $out
      cp -a $src/registryman-clusterrole.yaml $out
      cp -a $src/registryman-clusterrolebinding.yaml $out
      cp -a $src/registryman-webhook-vwc.yaml $out
      cp -a $src/registryman-webhook-service.yaml $out
      cp -a $src/registryman-webhook-deployment-verbose-patch.yaml $out
      cp -a $src/registryman-deployment-verbose-patch.yaml $out
    '';

  image-tag = builtins.hashString "sha256" (builtins.toString registryman-built);

  dockerimage = pkgs.dockerTools.buildLayeredImage {
    name = "registryman";
    tag = image-tag;
    config = {
      Entrypoint = [ "${registryman-built}/bin/registryman" ];
    };
  };

  controller-tools = pkgs.buildGoModule rec {
    pname = "controller-tools";
    version = controller-tools-config.version;

    excludedPackages = "pkg/loader/testmod";
    doCheck = false;
    src = pkgs.fetchFromGitHub {
      owner = "kubernetes-sigs";
      repo = "controller-tools";
      rev = "v${version}";
      sha256 = controller-tools-config.sha256;
    };

    vendorSha256 = controller-tools-config.vendorSha256;
  };

  code-generator = pkgs.buildGoModule rec {
    pname = "code-generator";
    version = code-generator-config.version;

    # doCheck = false;
    src = pkgs.fetchFromGitHub {
      owner = "kubernetes";
      repo = "code-generator";
      rev = "v${version}";
      sha256 = code-generator-config.sha256;
    };

    vendorSha256 = code-generator-config.vendorSha256;
  };

  collected-go-sources = pkgs.runCommand "collected-go-sources" {
  } ''
     mkdir -p $out/
     mkdir -p $TMPDIR/go
     cp -a ${pkgs.go}/share/go/* $TMPDIR/go
     chmod a+rw -R $TMPDIR/go
     cp -a ${registryman-local-vendor}/* $TMPDIR/go/src
     chmod a+rw -R $TMPDIR/go
     mkdir -p $TMPDIR/go/src/github.com/kubermatic-labs/registryman
     cp -a ${registryman-local-source}/* $TMPDIR/go/src/github.com/kubermatic-labs/registryman
     chmod a+rw -R $TMPDIR/go/src/github.com/kubermatic-labs/registryman
     mv $TMPDIR/go/* $out
  '';

  generated-code = pkgs.runCommand "registryman-generated" {
    nativeBuildInputs = [controller-tools code-generator pkgs.go ];
    GO111MODULE = "on";
    GOROOT = collected-go-sources;
  } ''
    mkdir -p $out/
    mkdir -p $TMPDIR/gocache
    export GOCACHE=$TMPDIR/gocache
    mkdir -p $TMPDIR/go/src/github.com/kubermatic-labs/registryman
    cp -a ${registryman-local-source}/* $TMPDIR/go/src/github.com/kubermatic-labs/registryman
    ln -s ${registryman-local-vendor} $TMPDIR/go/src/github.com/kubermatic-labs/registryman/vendor
    cd $TMPDIR/go/src/github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1
    deepcopy-gen -i github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1 \
                 -O zz_generated.deepcopy                                                \
                 -h ${collected-go-sources}/src/github.com/kubermatic-labs/registryman/hack/boilerplate.go.txt \
                 -o $TMPDIR/generated
    client-gen -i github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1 \
               -h ${collected-go-sources}/src/github.com/kubermatic-labs/registryman/hack/boilerplate.go.txt \
               --input "registryman/v1alpha1" \
               --input-base "github.com/kubermatic-labs/registryman/pkg/apis" \
               -p github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1/clientset \
               --clientset-name versioned \
               -o $TMPDIR/generated
    lister-gen -i github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1 \
               -h ${collected-go-sources}/src/github.com/kubermatic-labs/registryman/hack/boilerplate.go.txt \
               -p github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1/listers \
               -o $TMPDIR/generated
    informer-gen -i github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1 \
                 -h ${collected-go-sources}/src/github.com/kubermatic-labs/registryman/hack/boilerplate.go.txt \
                 -p github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1/informers \
                 --versioned-clientset-package github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1/clientset/versioned \
                 --listers-package github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1/listers \
                 -o $TMPDIR/generated
    register-gen -i github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1 \
                 -h ${collected-go-sources}/src/github.com/kubermatic-labs/registryman/hack/boilerplate.go.txt \
                 -p github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1/informers \
                 -o $TMPDIR/generated
    openapi-gen -i github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1 \
                -h ${collected-go-sources}/src/github.com/kubermatic-labs/registryman/hack/boilerplate.go.txt \
                -p github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1 \
                -o $TMPDIR/generated
    controller-gen crd output:dir=$TMPDIR/generated/github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1
    mv $TMPDIR/generated/github.com/kubermatic-labs/registryman/pkg/apis/registryman/v1alpha1/* $out
  '';

in {
  inherit registryman-built generated-code registryman-deployment-manifests
    registryman-deployment-manifests-verbose image-tag;

  shell = pkgs.mkShell {
    nativeBuildInputs = [ registryman-built ];
  };

  dev = pkgs.mkShell {
    nativeBuildInputs = [ controller-tools code-generator pkgs.go ];
    REGISTRYMAN_SRC = registryman-local-source;
    REGISTRYMAN_VENDOR = registryman-local-vendor;
    GO111MODULE = "on";
    GOROOT = collected-go-sources;
    REGISTRYMAN_GENERATED = generated-code;
  };
  docker = dockerimage;

  project-crd = "${registryman-generated}/pkg/apis/registryman/v1alpha1/registryman.kubermatic.com_projects.yaml";
  registry-crd = "${registryman-generated}/pkg/apis/registryman/v1alpha1/registryman.kubermatic.com_registries.yaml";
  scanner-crd = "${registryman-generated}/pkg/apis/registryman/v1alpha1/registryman.kubermatic.com_scanners.yaml";
}
