// Copyright 2022 Red Hat, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

package validate

import (
	"context"
	"errors"
	"fmt"
	"path"
	"strings"
	"sync"

	hd "github.com/MakeNowJust/heredoc"
	"github.com/hashicorp/go-multierror"
	app "github.com/redhat-appstudio/application-api/api/v1alpha1"
	"github.com/sigstore/cosign/v2/pkg/cosign"
	log "github.com/sirupsen/logrus"
	"github.com/spf13/afero"
	"github.com/spf13/cobra"

	"github.com/enterprise-contract/ec-cli/internal/applicationsnapshot"
	"github.com/enterprise-contract/ec-cli/internal/format"
	"github.com/enterprise-contract/ec-cli/internal/output"
	"github.com/enterprise-contract/ec-cli/internal/policy"
	"github.com/enterprise-contract/ec-cli/internal/policy/source"
	"github.com/enterprise-contract/ec-cli/internal/utils"
)

type imageValidationFunc func(context.Context, string, policy.Policy, bool) (*output.Output, error)

func validateImageCmd(validate imageValidationFunc) *cobra.Command {
	var data = struct {
		certificateIdentity         string
		certificateIdentityRegExp   string
		certificateOIDCIssuer       string
		certificateOIDCIssuerRegExp string
		effectiveTime               string
		filePath                    string
		imageRef                    string
		info                        bool
		input                       string
		output                      []string
		outputFile                  string
		policy                      policy.Policy
		policyConfiguration         string
		publicKey                   string
		rekorURL                    string
		snapshot                    string
		spec                        *app.SnapshotSpec
		strict                      bool
	}{

		// Default policy from an ECP cluster resource
		policyConfiguration: "enterprise-contract-service/default",
	}
	cmd := &cobra.Command{
		Use:   "image",
		Short: "Validate conformance of container images with the Enterprise Contract",

		Long: hd.Doc(`
			Validate conformance of container images with the Enterprise Contract

			For each image, validation is performed in stages to determine if the image
			conforms to the Enterprise Contract.

			The first validation stage determines if an image has been signed, and the
			signature matches the provided public key. This is akin to the "cosign verify"
			command.

			The second validation stage determines if one or more attestations exist, and
			those attestations have been signed matching the provided public key, similarly
			to the "cosign verify-attestation" command. This stage temporarily stores the
			attestations for usage in the next stage.

			The final stage verifies the attestations conform to rego policies defined in
			the EnterpriseContractPolicy.

			Validation advances each stage as much as possible for each image in order to
			capture all issues in a single execution.
		`),

		Example: hd.Doc(`
			Validate single image with the policy defined in the EnterpriseContractPolicy
			custom resource named "default" in the enterprise-contract-service Kubernetes
			namespace:

			  ec validate image --image registry/name:tag

			Validate multiple images from an ApplicationSnapshot Spec file:

			  ec validate image --file-path my-app.yaml

			Validate attestation of images from an inline ApplicationSnapshot Spec:

			  ec validate image --json-input '{"components":[{"containerImage":"<image url>"}]}'

			Use a different public key than the one from the EnterpriseContractPolicy resource:

			  ec validate image --image registry/name:tag --public-key <path/to/public/key>

			Use a different Rekor URL than the one from the EnterpriseContractPolicy resource:

			  ec validate image --image registry/name:tag --rekor-url https://rekor.example.org

			Return a non-zero status code on validation failure:

			  ec validate image --image registry/name:tag --strict

			Use an EnterpriseContractPolicy resource from the currently active kubernetes context:

			  ec validate image --image registry/name:tag --policy my-policy

			Use an EnterpriseContractPolicy resource from a different namespace:

			  ec validate image --image registry/name:tag --policy my-namespace/my-policy

			Use an inline EnterpriseContractPolicy spec
			  ec validate image --image registry/name:tag --policy '{"publicKey": "<path/to/public/key>"}'

			Write output in JSON format to a file
			  ec validate image --image registry/name:tag --output json=<path>

			Write output in YAML format to stdout and in HACBS format to a file
			  ec validate image --image registry/name:tag --output yaml --output hacbs=<path>

			Validate a single image with keyless workflow. This is an experimental feature
			that requires setting the EC_EXPERIMENTAL environment variable to "1".

			  EC_EXPERIMENTAL="1" ec validate image --image registry/name:tag --policy my-policy \
			    --certificate-identity 'https://github.com/user/repo/.github/workflows/push.yaml@refs/heads/main' \
			    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
			    --rekor-url 'https://rekor.sigstore.dev'

			Use a regular expression to match certificate attributes. This is an experimental
			feature that requires setting the EC_EXPERIMENTAL environment variable to "1".

			  EC_EXPERIMENTAL="1" ec validate image --image registry/name:tag --policy my-policy \
			    --certificate-identity-regexp '^https://github\.com' \
			    --certificate-oidc-issuer-regexp 'githubusercontent' \
			    --rekor-url 'https://rekor.sigstore.dev'
		`),

		PreRunE: func(cmd *cobra.Command, args []string) (allErrors error) {
			ctx := cmd.Context()
			if s, err := applicationsnapshot.DetermineInputSpec(ctx, applicationsnapshot.Input{
				File:     data.filePath,
				JSON:     data.input,
				Image:    data.imageRef,
				Snapshot: data.snapshot,
			}); err != nil {
				allErrors = multierror.Append(allErrors, err)
			} else {
				data.spec = s
			}

			identity := cosign.Identity{
				Issuer:        data.certificateOIDCIssuer,
				IssuerRegExp:  data.certificateOIDCIssuerRegExp,
				Subject:       data.certificateIdentity,
				SubjectRegExp: data.certificateIdentityRegExp,
			}

			// Check if policyConfiguration is a git url, if so then we need to download the config
			if strings.HasPrefix(data.policyConfiguration, "git::") || strings.HasPrefix(data.policyConfiguration, "github.com/") || strings.HasPrefix(data.policyConfiguration, "https://github.com/") {
				log.Debugf("Loading policy configuration from git url %s", data.policyConfiguration)

				// Create a temporary dir to download the config. This will be a different dir
				// to the workdir used later for the policy sources, but It doesn't matter much
				// because this dir is not needed after the config file is read.
				//
				fs := utils.FS(cmd.Context())
				tmpDir, err := utils.CreateWorkDir(fs)
				if err != nil {
					log.Debug("Failed to create tmp config dir!")
					allErrors = multierror.Append(allErrors, err)
					return
				}
				defer utils.CleanupWorkDir(fs, tmpDir)

				// Now download the config
				c := source.PolicyUrl{
					Url:  data.policyConfiguration,
					Kind: source.ConfigKind,
				}
				configDir, err := c.GetPolicy(ctx, tmpDir, false)
				if err != nil {
					log.Debugf("Failed to download config from %s", c.Url)
					allErrors = multierror.Append(allErrors, err)
					return
				}
				log.Debugf("Downloaded config from %s to %s", c.Url, configDir)

				// Currently the policy needs to be in a file called "policy.yaml" in the root
				// of whatever was downloaded. Todo maybe: Use a policy.json or policy.yml file
				// if it's there, or use any yaml or json file, as long as there's only one.
				//
				configFile := path.Join(configDir, "policy.yaml")
				fileExists, err := afero.Exists(fs, configFile)
				if err != nil {
					log.Debugf("Error checking if file %s exists", configFile)
					allErrors = multierror.Append(allErrors, err)
					return
				}
				if !fileExists {
					err = fmt.Errorf("The config source %s did not contain a policy.yaml file", data.policyConfiguration)
					allErrors = multierror.Append(allErrors, err)
					return
				}

				// The code directly below this knows how to read policy from a file. If we change the
				// value of data.policyConfiguration to the newly downloaded file we can make use of that.
				data.policyConfiguration = configFile
			}

			// Check if policyConfiguration is a file path, if so, we read it into the var data.policyConfiguration
			if strings.HasSuffix(data.policyConfiguration, ".yaml") || strings.HasSuffix(data.policyConfiguration, ".yml") || strings.HasSuffix(data.policyConfiguration, ".json") {
				fs := utils.FS(cmd.Context())
				policyBytes, err := afero.ReadFile(fs, data.policyConfiguration)
				if err != nil {
					allErrors = multierror.Append(allErrors, err)
					return
				}
				// Check for empty file as that would cause a false "success"
				if len(policyBytes) == 0 {
					err := fmt.Errorf("file %s is empty", data.policyConfiguration)
					allErrors = multierror.Append(allErrors, err)
					return
				}

				data.policyConfiguration = string(policyBytes)
			}

			if p, err := policy.NewPolicy(
				cmd.Context(), data.policyConfiguration, data.rekorURL, data.publicKey,
				data.effectiveTime, identity,
			); err != nil {
				allErrors = multierror.Append(allErrors, err)
			} else {
				data.policy = p
			}

			return
		},

		RunE: func(cmd *cobra.Command, args []string) error {
			type result struct {
				err       error
				component applicationsnapshot.Component
			}

			appComponents := data.spec.Components

			ch := make(chan result, len(appComponents))

			var lock sync.WaitGroup
			for _, c := range appComponents {
				lock.Add(1)
				go func(comp app.SnapshotComponent) {
					defer lock.Done()

					ctx := cmd.Context()
					out, err := validate(ctx, comp.ContainerImage, data.policy, data.info)
					res := result{
						err: err,
						component: applicationsnapshot.Component{
							SnapshotComponent: app.SnapshotComponent{
								Name:           comp.Name,
								ContainerImage: comp.ContainerImage,
							},
							Success: err == nil,
						},
					}

					// Skip on err to not panic. Error is return on routine completion.
					if err == nil {
						res.component.Violations = out.Violations()
						res.component.Warnings = out.Warnings()
						res.component.Successes = out.Successes()
						res.component.Signatures = out.Signatures
						res.component.ContainerImage = out.ImageURL
					}
					res.component.Success = err == nil && len(res.component.Violations) == 0

					ch <- res
				}(c)
			}

			lock.Wait()
			close(ch)

			var components []applicationsnapshot.Component
			var allErrors error = nil
			for r := range ch {
				if r.err != nil {
					e := fmt.Errorf("error validating image %s of component %s: %w", r.component.ContainerImage, r.component.Name, r.err)
					allErrors = multierror.Append(allErrors, e)
				} else {
					components = append(components, r.component)
				}
			}
			if allErrors != nil {
				return allErrors
			}

			if len(data.outputFile) > 0 {
				data.output = append(data.output, fmt.Sprintf("%s=%s", applicationsnapshot.JSON, data.outputFile))
			}

			report, err := applicationsnapshot.NewReport(data.snapshot, components, data.policy)
			if err != nil {
				return err
			}
			p := format.NewTargetParser(applicationsnapshot.JSON, cmd.OutOrStdout(), utils.FS(cmd.Context()))
			if err := report.WriteAll(data.output, p); err != nil {
				return err
			}

			if data.strict && !report.Success {
				// TODO: replace this with proper message and exit code 1.
				return errors.New("success criteria not met")
			}

			return nil
		},
	}

	cmd.Flags().StringVarP(&data.policyConfiguration, "policy", "p", data.policyConfiguration,
		"EnterpriseContractPolicy reference [<namespace>/]<name>")

	cmd.Flags().StringVarP(&data.imageRef, "image", "i", data.imageRef, "OCI image reference")

	cmd.Flags().StringVarP(&data.publicKey, "public-key", "k", data.publicKey,
		"path to the public key. Overrides publicKey from EnterpriseContractPolicy")

	cmd.Flags().StringVarP(&data.rekorURL, "rekor-url", "r", data.rekorURL,
		"Rekor URL. Overrides rekorURL from EnterpriseContractPolicy")

	cmd.Flags().StringVar(&data.certificateIdentity, "certificate-identity", data.certificateIdentity,
		"EXPERIMENTAL. URL of the certificate identity for keyless verification")

	cmd.Flags().StringVar(&data.certificateIdentityRegExp, "certificate-identity-regexp", data.certificateIdentityRegExp,
		"EXPERIMENTAL. Regular expression for the URL of the certificate identity for keyless verification")

	cmd.Flags().StringVar(&data.certificateOIDCIssuer, "certificate-oidc-issuer", data.certificateOIDCIssuer,
		"EXPERIMENTAL. URL of the certificate OIDC issuer for keyless verification")

	cmd.Flags().StringVar(&data.certificateOIDCIssuerRegExp, "certificate-oidc-issuer-regexp", data.certificateOIDCIssuerRegExp,
		"EXPERIMENTAL. Regular expresssion for the URL of the certificate OIDC issuer for keyless verification")

	cmd.Flags().StringVarP(&data.filePath, "file-path", "f", data.filePath,
		"path to ApplicationSnapshot Spec JSON file")

	cmd.Flags().StringVarP(&data.input, "json-input", "j", data.input,
		"JSON representation of an ApplicationSnapshot Spec")

	cmd.Flags().StringSliceVar(&data.output, "output", data.output, hd.Doc(`
		write output to a file in a specific format. Use empty string path for stdout.
		May be used multiple times. Possible formats are json, yaml, hacbs, junit, and
		summary
	`))

	cmd.Flags().StringVarP(&data.outputFile, "output-file", "o", data.outputFile,
		"[DEPRECATED] write output to a file. Use empty string for stdout, default behavior")

	cmd.Flags().BoolVarP(&data.strict, "strict", "s", data.strict,
		"return non-zero status on non-successful validation")

	cmd.Flags().StringVar(&data.effectiveTime, "effective-time", policy.Now, hd.Doc(`
		Run policy checks with the provided time. Useful for testing rules with
		effective dates in the future. The value can be "now" (default) - for
		current time, "attestation" - for time from the youngest attestation, or
		a RFC3339 formatted value, e.g. 2022-11-18T00:00:00Z.
	`))

	cmd.Flags().StringVar(&data.snapshot, "snapshot", "", hd.Doc(`
		Provide the AppStudio Snapshot as a source of the images to validate, as inline
		JSON of the "spec" or a reference to a Kubernetes object [<namespace>/]<name>`))

	cmd.Flags().BoolVar(&data.info, "info", data.info, hd.Doc(`
		Include additional information on the failures. For instance for policy
		violations, include the title and the description of the failed policy
		rule.`))

	if len(data.input) > 0 || len(data.filePath) > 0 {
		if err := cmd.MarkFlagRequired("image"); err != nil {
			panic(err)
		}
	}

	return cmd
}
