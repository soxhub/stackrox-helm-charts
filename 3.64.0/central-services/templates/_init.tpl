{{/*
    srox.init $

    Initialization template for the internal data structures.
    This template is designed to be included in every template file, but will only be executed
    once by leveraging state sharing between templates.
   */}}
{{ define "srox.init" }}

{{ $ := . }}

{{/*
    On first(!) instantiation, set up the $._rox structure, containing everything required by
    the resource template files.
   */}}
{{ if not $._rox }}

{{/*
    Initial Setup
   */}}

{{/*
    $rox / ._rox is the dictionary in which _all_ data that is modified by the init logic
    is stored.
    We ensure that it has the required shape, and then right after merging the user-specified
    $.Values, we apply some bootstrap defaults.
   */}}
{{ $rox := deepCopy $.Values }}
{{ $_ := set $ "_rox" $rox }}

{{/* Global state (accessed from sub-templates) */}}
{{ $generatedName := printf "stackrox-generated-%s" (randAlphaNum 6 | lower) }}
{{ $state := dict "customCertGen" false "generated" dict "generatedName" $generatedName "notes" list "warnings" list "referencedImages" dict }}
{{ $_ = set $._rox "_state" $state }}

{{ $configShape := $.Files.Get "internal/config-shape.yaml" | fromYaml }}
{{ $_ = include "srox.mergeInto" (list $rox $configShape (tpl ($.Files.Get "internal/bootstrap-defaults.yaml.tpl") . | fromYaml)) }}
{{ $_ = set $._rox "_configShape" $configShape }}

{{/*
    General validation.
   */}}
{{ if ne $.Release.Namespace "stackrox" }}
  {{ if $._rox.allowNonstandardNamespace }}
    {{ include "srox.note" (list $ (printf "You have chosen to deploy to namespace '%s'." $.Release.Namespace)) }}
  {{ else }}
    {{ include "srox.fail" (printf "You have chosen to deploy to namespace '%s', not 'stackrox'. If this was accidental, please re-run helm with the '-n stackrox' option. Otherwise, if you need to deploy into this namespace, set the 'allowNonstandardNamespace' configuration value to true." $.Release.Namespace) }}
  {{ end }}
{{ end }}

{{ if ne $.Release.Name $.Chart.Name }}
  {{ if $._rox.allowNonstandardReleaseName }}
    {{ include "srox.warn" (list $ (printf "You have chosen a release name of '%s', not '%s'. Accompanying scripts and commands in documentation might require adjustments." $.Release.Name $.Chart.Name)) }}
  {{ else }}
    {{ include "srox.fail" (printf "You have chosen a release name of '%s', not '%s'. We strongly recommend using the standard release name. If you must use a different name, set the 'allowNonstandardReleaseName' configuration option to true." $.Release.Name $.Chart.Name) }}
  {{ end }}
{{ end }}

{{/*
    Set prefix for global resources.
   */}}
{{ if kindIs "invalid" $._rox.globalPrefix }}
  {{ if eq $.Release.Namespace "stackrox" }}
    {{ $_ := set $._rox "globalPrefix" "stackrox" }}
  {{ else }}
    {{ $_ := set $._rox "globalPrefix" (printf "stackrox-%s" (trimPrefix "stackrox-" $.Release.Namespace)) }}
  {{ end }}
{{ end }}

{{ if ne $._rox.globalPrefix "stackrox" }}
  {{ include "srox.note" (list $ (printf "Global Kubernetes resources are prefixed with '%s'." $._rox.globalPrefix)) }}
{{ end }}

{{/*
    API Server setup. The problem with `.Capabilities.APIVersions` is that Helm does not
    allow setting overrides for those when using `helm template` or `--dry-run`. Thus,
    if we rely on `.Capabilities.APIVersions` directly, we lose flexibility for our chart
    in these settings. Therefore, we use custom fields such that a user in principle has
    the option to inject via `--set`/`-f` everything we rely upon.
   */}}
{{ $apiResources := list }}
{{ if not (kindIs "invalid" $._rox.meta.apiServer.overrideAPIResources) }}
  {{ $apiResources = $._rox.meta.apiServer.overrideAPIResources }}
{{ else }}
  {{ range $apiResource := $.Capabilities.APIVersions }}
    {{ $apiResources = append $apiResources $apiResource }}
  {{ end }}
{{ end }}
{{ if $._rox.meta.apiServer.extraAPIResources }}
  {{ $apiResources = concat $apiResources $._rox.meta.apiServer.extraAPIResources }}
{{ end }}
{{ $apiServerVersion := coalesce $._rox.meta.apiServer.version $.Capabilities.KubeVersion.Version }}
{{ $apiServer := dict "apiResources" $apiResources "version" $apiServerVersion }}
{{ $_ = set $._rox "_apiServer" $apiServer }}

{{/*
    Environment setup - part 1
   */}}
{{ $env := $._rox.env }}

{{/* Infer OpenShift, if needed */}}
{{ if kindIs "invalid" $env.openshift }}
  {{ $_ := set $env "openshift" (has "apps.openshift.io/v1" $._rox._apiServer.apiResources) }}
{{ end }}

{{/* Infer openshift version */}}
{{ if and $env.openshift (kindIs "bool" $env.openshift) }}
  {{/* Parse and add KubeVersion as semver from built-in resources. This is necessary to compare valid integer numbers. */}}
  {{ $kubeVersion := semver .Capabilities.KubeVersion.Version }}

  {{/* Default to OpenShift 3 if no openshift resources are available, i.e. in helm template commands */}}
  {{ if not (has "apps.openshift.io/v1" $._rox._apiServer.apiResources) }}
    {{ $_ := set $._rox.env "openshift" 3 }}
  {{ else if gt $kubeVersion.Minor 11 }}
    {{ $_ := set $env "openshift" 4 }}
  {{ else }}
    {{ $_ := set $env "openshift" 3 }}
  {{ end }}
  {{ include "srox.note" (list $ (printf "Based on API server properties, we have inferred that you are deploying into an OpenShift %d.x cluster. Set the `env.openshift` property explicitly to 3 or 4 to override the auto-sensed value." $env.openshift)) }}
{{ end }}
{{ if not (kindIs "bool" $env.openshift) }}
  {{ $_ := set $env "openshift" (int $env.openshift) }}
{{ else if not $env.openshift }}
  {{ $_ := set $env "openshift" 0 }}
{{ end }}

{{/* Infer GKE, if needed */}}
{{ if kindIs "invalid" $env.platform }}
  {{ $platform := "default" }}
  {{ if contains "-gke." $._rox._apiServer.version }}
    {{ include "srox.note" (list $ "Based on API server properties, we have inferred that you are deploying into a GKE cluster. Set the `env.platform` property to a concrete value to override the auto-sensed value.") }}
    {{ $platform = "gke" }}
  {{ end }}
  {{ $_ := set $env "platform" $platform }}
{{ end }}

{{/* Apply defaults */}}
{{ $defaultsCfg := dict }}
{{ $platformCfgFile := dict }}
{{ include "srox.loadFile" (list $ $platformCfgFile (printf "internal/platforms/%s.yaml" $env.platform)) }}
{{ if not $platformCfgFile.found }}
  {{ include "srox.fail" (printf "Invalid platform %q. Please select a valid platform, or leave this field unset." $env.platform) }}
{{ end }}
{{ $_ = include "srox.mergeInto" (list $defaultsCfg (fromYaml $platformCfgFile.contents) ($.Files.Get "internal/defaults.yaml" | fromYaml)) }}
{{ $_ = set $rox "_defaults" $defaultsCfg }}
{{ $_ = include "srox.mergeInto" (list $rox $defaultsCfg.defaults) }}


{{/* Expand applicable config values */}}
{{ $expandables := $.Files.Get "internal/expandables.yaml" | fromYaml }}
{{ include "srox.expandAll" (list $ $rox $expandables) }}

{{/* Initial image pull secret setup.

     Always assume that there are `stackrox` and `stackrox-scanner` image pull secrets,
     even if they weren't specified.
     This is required for updates anyway, so referencing it on first install will minimize a later
     diff. */}}
{{ include "srox.configureImagePullSecrets" (list $ "imagePullSecrets" $._rox.imagePullSecrets "stackrox" (list "stackrox" "stackrox-scanner") $.Release.Namespace) }}

{{/* Global CA setup */}}
{{ $caCertSpec := dict "CN" "StackRox Certificate Authority" "ca" true }}
{{ include "srox.configureCrypto" (list $ "ca" $caCertSpec) }}

{{/* Additional CAs. */}}
{{ $additionalCAList := list }}
{{ if kindIs "string" $._rox.additionalCAs }}
  {{ if trim $._rox.additionalCAs }}
    {{ $additionalCAList = append $additionalCAList (dict "name" "ca.crt" "contents" $._rox.additionalCAs) }}
  {{ end }}
{{ else if kindIs "slice" $._rox.additionalCAs }}
  {{ range $contents := $._rox.additionalCAs }}
    {{ $additionalCAList = append $additionalCAList (dict "name" "ca.crt" "contents" $contents) }}
  {{ end }}
{{ else if kindIs "map" $._rox.additionalCAs }}
  {{ range $name := keys $._rox.additionalCAs | sortAlpha }}
    {{ $additionalCAList = append $additionalCAList (dict "name" $name "contents" (get $._rox.additionalCAs $name)) }}
  {{ end }}
{{ else if not (kindIs "invalid" $._rox.additionalCAs) }}
  {{ include "srox.fail" (printf "Invalid kind %s for additionalCAs" (kindOf $._rox.additionalCAs)) }}
{{ end }}
{{ range $path, $contents := .Files.Glob "secrets/additional-cas/**" }}
  {{ $name := trimPrefix "secrets/additional-cas/" $path }}
  {{ $additionalCAList = append $additionalCAList (dict "name" $name "contents" (toString $contents)) }}
{{ end }}
{{ $additionalCAs := dict }}
{{ range $idx, $elem := $additionalCAList }}
  {{ if not (kindIs "string" $elem.contents) }}
    {{ include "srox.fail" (printf "Invalid non-string contents kind %s at index %d (%q) of additionalCAs" (kindOf $elem.contents) $idx $elem.name) }}
  {{ end }}
  {{/* In a k8s secret, no characters other than alphanumeric, '.', '_' and '-' are allowed. Also, for the
       update-ca-certificates script to work, the file names must end in '.crt'. */}}

  {{ $normalizedName := printf "%02d-%s.crt" $idx (regexReplaceAll "[^[:alnum:]._-]" $elem.name "-" | trimSuffix ".crt") }}
  {{ $_ := set $additionalCAs $normalizedName $elem.contents }}
{{ end }}
{{ $_ = set $._rox "_additionalCAs" $additionalCAs }}

{{/* Proxy configuration.
     Note: The reason this is different is that unlike the endpoints config, the proxy configuration
     might contain sensitive data and thus might _not_ be stored in the always available canonical
     values file. However, this is probably rare. Therefore, for this particular instance we do decide
     to rely on lookup magic for initially populating the secret with a default proxy config.
     However, we won't take any chances, and therefore only create that secret if we can be reasonably
     confident that lookup actually works, by trying to lookup the default service account.
   */}}
{{ $proxyCfg := $env._proxyConfig }}
{{ $fileOut := dict }}
{{ include "srox.loadFile" (list $ $fileOut "config/proxy-config.yaml") }}
{{ if $fileOut.found }}
  {{ if not (kindIs "invalid" $proxyCfg) }}
    {{ include "srox.fail" "Both env.proxyConfig was specified, and a config/proxy-config.yaml was found. Please remove/rename the config file, or comment out the env.proxyConfig stanza." }}
  {{ end }}
  {{ $proxyCfg = $fileOut.contents }}
{{ end }}

{{/* On first install, create a default proxy config, but only if we can be sure none exists. */}}
{{ if and (kindIs "invalid" $proxyCfg) $.Release.IsInstall }}
  {{ $lookupOut := dict }}
  {{ include "srox.safeLookup" (list $ $lookupOut "v1" "Secret" $.Release.Namespace "proxy-config") }}
  {{ if and $lookupOut.reliable (not $lookupOut.result) }}
    {{ $fileOut := dict }}
    {{ include "srox.loadFile" (list $ $fileOut "config/proxy-config.yaml.default") }}
    {{ $proxyCfg = $fileOut.contents }}
  {{ end }}
{{ end }}
{{ $_ = set $env "_proxyConfig" $proxyCfg }}

{{/*
    Central setup.
   */}}


{{ include "srox.centralSetup" $ }}


{{/*
    Scanner setup.
   */}}

{{ $scannerCfg := $._rox.scanner }}

{{ if and $scannerCfg.disable (or $.Release.IsInstall $.Release.IsUpgrade) }}
  {{/* We generally don't recommend customers run without scanner, so show a warning to the user */}}
  {{ $action := ternary "deploy StackRox Central Services without Scanner" "upgrade StackRox Central Services without Scanner (possibly removing an existing Scanner deployment)" $.Release.IsInstall }}
  {{ include "srox.warn" (list $ (printf "You have chosen to %s. Certain features dependent on image scanning might not work." $action)) }}
{{ else if not $scannerCfg.disable }}
  {{ include "srox.configureImage" (list $ $scannerCfg.image) }}
  {{ include "srox.configureImage" (list $ $scannerCfg.dbImage) }}

  {{ $scannerCertSpec := dict "CN" "SCANNER_SERVICE: Scanner" "dnsBase" "scanner" }}
  {{ include "srox.configureCrypto" (list $ "scanner.serviceTLS" $scannerCertSpec) }}

  {{ $scannerDBCertSpec := dict "CN" "SCANNER_DB_SERVICE: Scanner DB" "dnsBase" "scanner-db" }}
  {{ include "srox.configureCrypto" (list $ "scanner.dbServiceTLS" $scannerDBCertSpec) }}

  {{ include "srox.configurePassword" (list $ "scanner.dbPassword") }}
{{ end }}


{{/*
    Post-processing steps.
   */}}


{{/* Compact the post-processing config to prevent it from appearing non-empty if it doesn't
     contain any concrete (leaf) values. */}}
{{ include "srox.compactDict" (list $._rox._state.generated -1) }}

{{/* Setup Image Pull Secrets for Docker Registry.
     Note: This must happen afterwards, as we rely on "srox.configureImage" to collect the
     set of all referenced images first. */}}
{{ include "srox.configureImagePullSecretsForDockerRegistry" (list $ ._rox.imagePullSecrets) }}

{{/* Final warnings based on state. */}}
{{ if $._rox._state.customCertGen }}
  {{ include "srox.warn" (list $ "At least one certificate was generated by Helm. Helm limits the generation of custom certificates to RSA private keys, which have poorer computational performance. Consider using roxctl for certificate generation of certificates with ECDSA private keys for improved performance. (THIS IS NOT A SECURITY ISSUE)") }}
{{ end }}

{{ end }}

{{ end }}
