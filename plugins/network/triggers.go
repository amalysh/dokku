package network

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/dokku/dokku/plugins/common"
)

// TriggerDockerArgsProcess outputs the network plugin docker options for an app
func TriggerDockerArgsProcess(stage string, appName string, imageSourceType string) error {
	stdin, err := io.ReadAll(os.Stdin)
	if err != nil {
		return err
	}

	if stage == "build" && imageSourceType == "dockerfile" {
		fmt.Print(string(stdin))
		return nil
	}

	initialNetwork := reportComputedInitialNetwork(appName)
	if initialNetwork != "" {
		fmt.Printf(" --network=%s ", initialNetwork)
	}

	fmt.Print(string(stdin))
	return nil
}

// TriggerInstall runs the install step for the network plugin
func TriggerInstall() error {
	if err := common.PropertySetup("network"); err != nil {
		return fmt.Errorf("Unable to install the network plugin: %s", err.Error())
	}

	apps, err := common.UnfilteredDokkuApps()
	if err != nil {
		return nil
	}

	for _, appName := range apps {
		if common.PropertyExists("network", appName, "bind-all-interfaces") {
			continue
		}
		_, err := common.CallPlugnTrigger(common.PlugnTriggerInput{
			Trigger:     "proxy-is-enabled",
			Args:        []string{appName},
			StreamStdio: true,
		})
		if err != nil {
			common.LogVerboseQuiet("Setting network property 'bind-all-interfaces' to false")
			if err := common.PropertyWrite("network", appName, "bind-all-interfaces", "false"); err != nil {
				common.LogWarn(err.Error())
			}
		} else {
			common.LogVerboseQuiet("Setting network property 'bind-all-interfaces' to true")
			if err := common.PropertyWrite("network", appName, "bind-all-interfaces", "true"); err != nil {
				common.LogWarn(err.Error())
			}
		}
	}

	return nil
}

// TriggerNetworkConfigExists writes true or false to stdout whether a given app has network config
func TriggerNetworkConfigExists(appName string) error {
	if HasNetworkConfig(appName) {
		fmt.Println("true")
		return nil
	}

	fmt.Println("false")
	return nil
}

// TriggerNetworkGetIppaddr writes the ipaddress to stdout for a given app container
func TriggerNetworkGetIppaddr(appName string, processType string, containerID string) error {
	ipAddress := GetContainerIpaddress(appName, processType, containerID)
	fmt.Println(ipAddress)
	return nil
}

// TriggerNetworkGetListeners returns the listeners (host:port combinations) for a given app container
func TriggerNetworkGetListeners(appName string, processType string) error {
	if processType == "" {
		common.LogWarn("Deprecated: Please specify a processType argument for the network-get-listeners plugin trigger")
		processType = "web"
	}
	listeners := GetListeners(appName, processType)
	fmt.Println(strings.Join(listeners, " "))
	return nil
}

// TriggerNetworkGetProperty writes the network property to stdout for a given app container
func TriggerNetworkGetProperty(appName string, property string) error {
	computedValueMap := map[string]common.ReportFunc{
		"attach-post-create":  reportComputedAttachPostCreate,
		"attach-post-deploy":  reportComputedAttachPostDeploy,
		"bind-all-interfaces": reportComputedBindAllInterfaces,
		"initial-network":     reportComputedInitialNetwork,
		"tld":                 reportComputedTld,
	}

	fn, ok := computedValueMap[property]
	if !ok {
		return fmt.Errorf("Invalid network property specified: %v", property)
	}

	fmt.Println(fn(appName))
	return nil
}

// TriggerNetworkGetStaticListeners fetches the static listener for the specified app/processType combination
func TriggerNetworkGetStaticListeners(appName string, processType string) error {
	staticWebListener := reportStaticWebListener(appName)
	fmt.Println(staticWebListener)
	return nil
}

// TriggerNetworkWriteIpaddr writes the ip to disk
func TriggerNetworkWriteIpaddr(appName string, processType string, containerIndex string, ip string) error {
	appRoot := common.AppRoot(appName)
	filename := fmt.Sprintf("%v/IP.%v.%v", appRoot, processType, containerIndex)
	f, err := os.Create(filename)
	if err != nil {
		return err
	}
	defer f.Close()

	ipBytes := []byte(ip)
	_, err = f.Write(ipBytes)
	if err != nil {
		return err
	}

	return nil
}

// TriggerNetworkWritePort writes the port to disk
func TriggerNetworkWritePort(appName string, processType string, containerIndex string, port string) error {
	appRoot := common.AppRoot(appName)
	filename := fmt.Sprintf("%v/PORT.%v.%v", appRoot, processType, containerIndex)
	f, err := os.Create(filename)
	if err != nil {
		return err
	}
	defer f.Close()

	portBytes := []byte(port)
	_, err = f.Write(portBytes)
	if err != nil {
		return err
	}

	return nil
}

// TriggerPostAppCloneSetup creates new network files
func TriggerPostAppCloneSetup(oldAppName string, newAppName string) error {
	success := ClearNetworkConfig(newAppName)
	if !success {
		os.Exit(1)
	}

	err := common.PropertyClone("network", oldAppName, newAppName)
	if err != nil {
		return err
	}

	return nil
}

// TriggerPostAppRenameSetup renames network files
func TriggerPostAppRenameSetup(oldAppName string, newAppName string) error {
	success := ClearNetworkConfig(newAppName)
	if !success {
		os.Exit(1)
	}

	if err := common.PropertyClone("network", oldAppName, newAppName); err != nil {
		return err
	}

	if err := common.PropertyDestroy("network", oldAppName); err != nil {
		return err
	}

	return nil
}

// TriggerPostContainerCreate associates the container with a specified network
func TriggerPostContainerCreate(containerType string, containerID string, appName string, phase string, processType string) error {
	if containerType != "app" {
		return nil

	}

	networks := reportComputedAttachPostCreate(appName)
	if networks == "" {
		return nil

	}

	for _, networkName := range strings.Split(networks, ",") {
		exists, err := networkExists(networkName)
		if err != nil {
			return err
		}

		if !exists {
			return fmt.Errorf("Network %v does not exist", networkName)
		}

		return attachAppToNetwork(containerID, networkName, appName, phase, processType)
	}

	return nil
}

// TriggerPostCreate sets bind-all-interfaces to false by default
func TriggerPostCreate(appName string) error {
	err := common.PropertyWrite("network", appName, "bind-all-interfaces", "false")
	if err != nil {
		common.LogWarn(err.Error())
	}

	return nil
}

// TriggerPostDelete destroys the network property for a given app container
func TriggerPostDelete(appName string) error {
	return common.PropertyDestroy("network", appName)
}

// TriggerCorePostDeploy associates the container with a specified network
func TriggerCorePostDeploy(appName string) error {
	networks := reportComputedAttachPostDeploy(appName)
	if networks == "" {
		return nil
	}

	for _, networkName := range strings.Split(networks, ",") {
		common.LogInfo1Quiet(fmt.Sprintf("Associating app with network %s", networkName))
		containerIDs, err := common.GetAppRunningContainerIDs(appName, "")
		if err != nil {
			return err
		}

		exists, err := networkExists(networkName)
		if err != nil {
			return err
		}

		if !exists {
			return fmt.Errorf("Network %v does not exist", networkName)
		}

		for _, containerID := range containerIDs {
			processType, err := common.DockerInspect(containerID, "{{ index .Config.Labels \"com.dokku.process-type\"}}")
			if err != nil {
				return err
			}
			if err := attachAppToNetwork(containerID, networkName, appName, "deploy", processType); err != nil {
				return err
			}
		}
	}

	return nil
}
