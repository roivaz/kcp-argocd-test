package health_check

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ghodss/yaml"
	"github.com/stretchr/testify/assert"
)

type TestStructure struct {
	Tests []IndividualTest `yaml:"tests"`
}

type IndividualTest struct {
	InputPath    string       `yaml:"inputPath"`
	HealthStatus HealthStatus `yaml:"healthStatus"`
}

// Represents resource health status
type HealthStatusCode string

const (
	// Indicates that health assessment failed and actual health status is unknown
	HealthStatusUnknown HealthStatusCode = "Unknown"
	// Progressing health status means that resource is not healthy but still have a chance to reach healthy state
	HealthStatusProgressing HealthStatusCode = "Progressing"
	// Resource is 100% healthy
	HealthStatusHealthy HealthStatusCode = "Healthy"
	// Assigned to resources that are suspended or paused. The typical example is a
	// [suspended](https://kubernetes.io/docs/tasks/job/automated-tasks-with-cron-jobs/#suspend) CronJob.
	HealthStatusSuspended HealthStatusCode = "Suspended"
	// Degrade status is used if resource status indicates failure or resource could not reach healthy state
	// within some timeout.
	HealthStatusDegraded HealthStatusCode = "Degraded"
	// Indicates that resource is missing in the cluster.
	HealthStatusMissing HealthStatusCode = "Missing"
)

// Holds health assessment results
type HealthStatus struct {
	Status  HealthStatusCode `json:"status,omitempty"`
	Message string           `json:"message,omitempty"`
}

func TestLuaHealthScript(t *testing.T) {
	err := filepath.Walk("./",
		func(path string, f os.FileInfo, err error) error {

			if !strings.Contains(path, "health.lua") {
				return nil
			}
			checkError(err, t)
			dir := filepath.Dir(path)
			yamlBytes, err := os.ReadFile(dir + "/health_test.yaml")
			checkError(err, t)
			var resourceTest TestStructure
			err = yaml.Unmarshal(yamlBytes, &resourceTest)
			checkError(err, t)

			for i := range resourceTest.Tests {
				test := resourceTest.Tests[i]

				t.Run(test.InputPath, func(t *testing.T) {
					cmd := exec.Command("bash", "-c", buildBashCommand(dir, test.InputPath))
					var stdout, stderr bytes.Buffer
					cmd.Stdout = &stdout
					cmd.Stderr = &stderr
					err := cmd.Run()
					if err != nil {
						t.Errorf("%s: %s\n", err, stderr.String())
					}
					result := parseCommandOutput(&stdout, t)
					assert.Equal(t, &test.HealthStatus, result)
				})
			}
			return nil
		},
	)
	assert.Nil(t, err)
}

const relativePath string = "../../../"

func buildBashCommand(dir, input string) string {

	kustomizeBin := relativePath + "bin/kustomize"
	yqBin := relativePath + "bin/yq"
	argocdBin := relativePath + "bin/argocd"

	command := strings.Join([]string{
		strings.Join(
			[]string{kustomizeBin, "build", relativePath + "argocd/argocd-install"}, " "),
		strings.Join(
			[]string{yqBin, `'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm")'`}, " "),
		strings.Join(
			[]string{argocdBin, "admin settings resource-overrides health", filepath.Join(dir, input), "--argocd-cm-path /dev/stdin"}, " "),
	}, " | ")

	return command
}

func parseCommandOutput(output *bytes.Buffer, t *testing.T) *HealthStatus {

	hs := &HealthStatus{}
	scanner := bufio.NewScanner(output)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.Split(line, ":")
		if parts[0] == "MESSAGE" {
			hs.Message = strings.TrimSpace(parts[1])
		} else if parts[0] == "STATUS" {
			hs.Status = HealthStatusCode(strings.TrimSpace(parts[1]))
		} else {
			// Let anmy other output go to stdout
			t.Logf("%v", line)
		}
	}

	return hs
}

func checkError(err error, t *testing.T) {
	if err != nil {
		t.Error(err)
	}
}
