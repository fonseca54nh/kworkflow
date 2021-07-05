#
# The `deploy.sh` file centralizes functions related to kernel installation.
# With kworkflow, we want to handle three scenarios:
#
# 1. Virtual Machine (VM): we want to provide support for developers that uses
#    VM during their work with Linux Kernel, because of this kw provide
#    essential features for this case.
# 2. Local: we provide support for users to utilize their machine as a target.
# 3. Remote: we provide support for deploying kernel in a remote machine. It is
#    important to highlight that a VM in the localhost can be treated as a
#    remote machine.
#
# Usually, installing modules and updating the kernel image requires root
# permission. With this idea in mind we rely on the `/root` in the remote
# machine. Additionally, for local deploy you will be asked to enter your root
# password.
#

include "$KW_LIB_DIR/vm.sh" # It includes kw_config_loader.sh and kwlib.sh
include "$KW_LIB_DIR/remote.sh"
include "$KW_LIB_DIR/signal_manager.sh"

# Hash containing user options
declare -gA options_values

# This function is responsible for handling the command to
# `make install_modules`, and it expects a target path for saving the modules
# files.
#
# @install_to Target path to install the output of the command `make
#             modules_install`.
# @flag How to display a command, see `src/kwlib.sh` function `cmd_manager`
function modules_install_to()
{
  local install_to="$1"
  local flag="$2"

  flag=${flag:-""}

  if ! is_kernel_root "$PWD"; then
    complain "Execute this command in a kernel tree."
    exit 125 # ECANCELED
  fi

  local cmd="make INSTALL_MOD_PATH=$install_to modules_install"
  set +e
  cmd_manager "$flag" "$cmd"
}

# This function goal is to perform a global clean up, it basically calls other
# specialized cleanup functions.
function cleanup()
{
  say 'Cleanup deploy files'
  cleanup_after_deploy
}

function interrupt_cleanup()
{
  say 'Cleaning up...'
  if [[ -v options_values['REMOTE'] ]]; then
    cleanup_after_deploy 'SILENT'
  fi

  say 'Exiting...'
  exit 0
}

# When kw deploy a new kernel it creates temporary files to be used for moving
# to the target machine. There is no need to keep those files in the user
# machine, for this reason, this function is in charge of cleanup the temporary
# files at the end.
#
# @flag How to display a command, the default value is
#   "SILENT". For more options see `src/kwlib.sh` function `cmd_manager`
function cleanup_after_deploy()
{
  local flag="$1"

  if [[ -d "$KW_CACHE_DIR/$LOCAL_REMOTE_DIR" ]]; then
    cmd_manager "$flag" "rm -rf $KW_CACHE_DIR/$LOCAL_REMOTE_DIR/*"
  fi

  if [[ -d "$KW_CACHE_DIR/$LOCAL_TO_DEPLOY_DIR" ]]; then
    cmd_manager "$flag" "rm -rf $KW_CACHE_DIR/$LOCAL_TO_DEPLOY_DIR/*"
  fi
}

# This function expects a parameter that specifies the target machine;
# in the first case, the host machine is the target, and otherwise the virtual
# machine.
#
# @target Target machine
function modules_install()
{
  local flag="$1"
  local target="$2"
  local formatted_remote="$3"
  local remote
  local port
  local distro

  if ! is_kernel_root "$PWD"; then
    complain "Execute this command in a kernel tree."
    exit 125 # ECANCELED
  fi

  flag=${flag:-""}

  case "$target" in
    1) # VM_TARGET
      distro=$(detect_distro "${configurations[mount_point]}/")

      if [[ "$distro" =~ "none" ]]; then
        complain "Unfortunately, there's no support for the target distro"
        vm_umount
        exit 95 # ENOTSUP
      fi

      modules_install_to "${configurations[mount_point]}" "$flag"
      ;;
    2) # LOCAL_TARGET
      cmd="sudo -E make modules_install"
      cmd_manager "$flag" "$cmd"
      ;;
    3) # REMOTE_TARGET
      # 1. Preparation steps
      prepare_host_deploy_dir

      remote="${options_values['REMOTE_IP']}"
      port="${options_values['REMOTE_PORT']}"

      prepare_remote_dir "$remote" "$port" "" "$flag"

      # 2. Send files modules
      modules_install_to "$KW_CACHE_DIR/$LOCAL_REMOTE_DIR/" "$flag"

      release=$(get_kernel_release "$flag")
      success "Kernel: $release"
      generate_tarball "$release" "" "$flag"

      local tarball_for_deploy_path="$KW_CACHE_DIR/$LOCAL_TO_DEPLOY_DIR/$release.tar"
      cp_host2remote "$tarball_for_deploy_path" \
        "$REMOTE_KW_DEPLOY" "$remote" "$port" "" "$flag"

      # 3. Deploy: Execute script
      local cmd="bash $REMOTE_KW_DEPLOY/deploy.sh --modules $release.tar"
      cmd_remotely "$cmd" "$flag" "$remote" "$port"
      ;;
  esac
}

# This function list all the available kernels in a VM, local, and remote
# machine. This code relies on `kernel_install` plugin, more precisely on
# `utils.sh` file which comprises all the required operations for listing new
# Kernels.
#
# @flag How to display a command, the default value is
#   "SILENT". For more options see `src/kwlib.sh` function `cmd_manager`
# @single_line If this option is set to 1 this function will display all
#   available kernels in a single line separated by commas. If it gets 0 it
#   will display each kernel name by line.
# @target Target can be 1 (VM_TARGET), 2 (LOCAL_TARGET), and 3 (REMOTE_TARGET)
# @unformatted_remote We expect the REMOTE:PORT string
function list_installed_kernels()
{
  local flag="$1"
  local single_line="$2"
  local target="$3"
  local unformatted_remote="$4"
  local remote
  local port

  flag=${flag:-"SILENT"}

  case "$target" in
    1) # VM_TARGET
      vm_mount

      if [ "$?" != 0 ]; then
        complain "Did you check if your VM is running?"
        return 125 # ECANCELED
      fi

      . "$KW_PLUGINS_DIR/kernel_install/utils.sh" --source-only
      list_installed_kernels "$single_line" "${configurations[mount_point]}"

      vm_umount
      ;;
    2) # LOCAL_TARGET
      . "$KW_PLUGINS_DIR/kernel_install/utils.sh" --source-only
      list_installed_kernels "$single_line"
      ;;
    3) # REMOTE_TARGET
      local cmd="bash $REMOTE_KW_DEPLOY/deploy.sh --list_kernels $single_line"
      remote="${options_values['REMOTE_IP']}"
      port="${options_values['REMOTE_PORT']}"

      prepare_remote_dir "$remote" "$port" "" "$flag"

      cmd_remotely "$cmd" "$flag" "$remote" "$port"
      ;;
  esac

  return 0
}

# This function behaves like a kernel installation manager. It handles some
# parameters, and it also prepares to deploy the new kernel in the target
# machine.
#
# @reboot If this value is equal 1, it means reboot machine after kernel
#         installation.
# @name Kernel name to be deployed.
#
# Note:
# Take a look at the available kernel plugins at: src/plugins/kernel_install
function kernel_install()
{
  local reboot="$1"
  local name="$2"
  local flag="$3"
  local target="$4"
  local user=""
  local distro="none"
  local kernel_name="${configurations[kernel_name]}"
  local mkinitcpio_name="${configurations[mkinitcpio_name]}"
  local arch_target="${configurations[arch]}"
  local kernel_img_name="${configurations[kernel_img_name]}"
  local remote
  local port
  local distro

  if ! is_kernel_root "$PWD"; then
    complain "Execute this command in a kernel tree."
    exit 125 # ECANCELED
  fi

  # We have to guarantee some default values values
  kernel_name=${kernel_name:-"nothing"}
  mkinitcpio_name=${mkinitcpio_name:-"nothing"}
  name=${name:-"kw"}
  flag=${flag:-""}

  if [[ "$reboot" == 0 ]]; then
    reboot_default="${configurations[reboot_after_deploy]}"
    if [[ "$reboot_default" =~ "yes" ]]; then
      reboot=1
    fi
  fi

  if [[ ! -f "arch/$arch_target/boot/$kernel_img_name" ]]; then
    # Try to infer the kernel image name
    kernel_img_name=$(find "arch/$arch_target/boot/" -name "*Image" 2> /dev/null)
    if [[ -z "$kernel_img_name" ]]; then
      complain "We could not find a valid kernel image at arch/$arch_target/boot"
      complain "Please, check your compilation and/or the option kernel_img_name inside kworkflow.config"
      exit 125 # ECANCELED
    fi
    warning "kw inferred arch/$arch_target/boot/$kernel_img_name as a kernel image"
  fi

  case "$target" in
    1) # VM_TARGET
      distro=$(detect_distro "${configurations[mount_point]}/")

      if [[ "$distro" =~ "none" ]]; then
        complain "Unfortunately, there's no support for the target distro"
        vm_umount
        exit 95 # ENOTSUP
      fi

      . "$KW_PLUGINS_DIR/kernel_install/utils.sh" --source-only
      . "$KW_PLUGINS_DIR/kernel_install/$distro.sh" --source-only
      install_kernel "$name" "$distro" "$kernel_img_name" "$reboot" "$arch_target" 'vm' "$flag"
      return "$?"
      ;;
    2) # LOCAL_TARGET
      distro=$(detect_distro "/")

      if [[ "$distro" =~ "none" ]]; then
        complain "Unfortunately, there's no support for the target distro"
        exit 95 # ENOTSUP
      fi

      # Local Deploy
      if [[ $(id -u) == 0 ]]; then
        complain "kw deploy --local should not be run as root"
        exit 1 # EPERM
      fi

      . "$KW_PLUGINS_DIR/kernel_install/utils.sh" --source-only
      . "$KW_PLUGINS_DIR/kernel_install/$distro.sh" --source-only
      install_kernel "$name" "$distro" "$kernel_img_name" "$reboot" "$arch_target" 'local' "$flag"
      return "$?"
      ;;
    3) # REMOTE_TARGET
      local preset_file="$KW_CACHE_DIR/$LOCAL_TO_DEPLOY_DIR/$name.preset"
      if [[ ! -f "$preset_file" ]]; then
        template_mkinit="$KW_ETC_DIR/template_mkinitcpio.preset"
        cp "$template_mkinit" "$preset_file"
        sed -i "s/NAME/$name/g" "$preset_file"
      fi

      remote="${options_values['REMOTE_IP']}"
      port="${options_values['REMOTE_PORT']}"

      distro_info=$(which_distro "$remote" "$port" "$user")
      distro=$(detect_distro "/" "$distro_info")

      cp_host2remote "$KW_CACHE_DIR/$LOCAL_TO_DEPLOY_DIR/$name.preset" \
        "$REMOTE_KW_DEPLOY" \
        "$remote" "$port" "$user" "$flag"
      cp_host2remote "arch/$arch_target/boot/$kernel_img_name" \
        "$REMOTE_KW_DEPLOY/vmlinuz-$name" \
        "$remote" "$port" "$user" "$flag"

      # Deploy
      local cmd_parameters="$name $distro $kernel_img_name $reboot $arch_target 'remote' $flag"
      local cmd="bash $REMOTE_KW_DEPLOY/deploy.sh --kernel_update $cmd_parameters"
      cmd_remotely "$cmd" "$flag" "$remote" "$port"
      ;;
  esac
}

# This function handles the kernel uninstall process for different targets.
#
# @target Target machine Target machine Target machine Target machine
# @reboot If this value is equal 1, it means reboot machine after kernel
#         installation.
# @formatted_remote Remote formatted as IP:PORT or USE@MACHINE:PORT
# @kernels_target List containing kernels to be uninstalled
# @flag How to display a command, see `src/kwlib.sh` function `cmd_manager`
#
# Return:
# Return 0 if everything is correct or an error in case of failure
function kernel_uninstall()
{
  local target="$1"
  local reboot="$2"
  local formatted_remote="$3"
  local kernels_target="$4"
  local flag="$5"
  local distro
  local remote
  local port

  flag=${flag:-""}

  case "$target" in
    1) # VM_TARGET
      echo "UNINSTALL VM"
      ;;
    2) # LOCAL_TARGET
      distro=$(detect_distro "/")

      if [[ "$distro" =~ "none" ]]; then
        complain "Unfortunately, there's no support for the target distro"
        exit 95 # ENOTSUP
      fi

      # Local Deploy
      # We need to update grub, for this reason we to load specific scripts.
      . "$KW_PLUGINS_DIR/kernel_install/$distro.sh" --source-only
      . "$KW_PLUGINS_DIR/kernel_install/utils.sh" --source-only
      kernel_uninstall "$reboot" 'local' "$kernels_target" "$flag"
      ;;
    3) # REMOTE_TARGET
      remote="${options_values['REMOTE_IP']}"
      port="${options_values['REMOTE_PORT']}"

      prepare_remote_dir "$remote" "$port" "" "$flag"

      # Deploy
      # TODO
      # It would be better if `cmd_remotely` handle the extra space added by
      # line break with `\`; this may allow us to break a huge line like this.
      local cmd="bash $REMOTE_KW_DEPLOY/deploy.sh --uninstall_kernel $reboot remote $kernels_target $flag"
      cmd_remotely "$cmd" "$flag" "$remote" "$port"
      ;;
  esac
}

# From kw perspective, deploy a new kernel is composed of two steps: install
# modules and update kernel image. I chose this approach for reducing the
# chances of break the system due to modules and kernel mismatch. This function
# is responsible for handling some of the userspace options and calls the
# required functions to update the kernel. This function handles a different
# set of parameters for the distinct set of target machines.
#
# Note: I know that developer know what they are doing (usually) and in the
# future, it will be nice if we support single kernel update (patches are
# welcome).
#
# @reboot If 1 the target machine will be rebooted after the kernel update
# @name Kernel name for the deploy
function kernel_deploy()
{
  local reboot=0
  local modules=0
  local target=0
  local test_mode=""
  local list=0
  local single_line=0
  local uninstall=""
  local start=0
  local end=0
  local runtime=0
  local ret=0

  if [[ "$1" == -h ]]; then
    deploy_help
    exit 0
  fi

  deploy_parser_options "$@"
  if [[ "$?" -gt 0 ]]; then
    complain "Invalid option: ${options_values['ERROR']}"
    exit 22 # EINVAL
  fi

  target="${options_values['TARGET']}"
  reboot="${options_values['REBOOT']}"
  modules="${options_values['MODULES']}"
  single_line="${options_values['LS_LINE']}"
  list="${options_values['LS']}"
  test_mode="${options_values['TEST_MODE']}"
  remote="${options_values['REMOTE']}"
  uninstall="${options_values["UNINSTALL"]}"

  if [[ "$test_mode" == "TEST_MODE" ]]; then
    echo "$reboot $modules $target ${options_values['REMOTE_IP']} ${options_values['REMOTE_PORT']} $single_line $list"
    return 0
  fi

  if [[ "$list" == 1 || "$single_line" == 1 ]]; then
    say "Available kernels:"
    start=$(date +%s)
    list_installed_kernels "" "$single_line" "$target" "$remote"
    end=$(date +%s)

    runtime=$((end - start))
    statistics_manager "list" "$runtime"
    return "$?"
  fi

  if [[ ! -z "$uninstall" ]]; then
    start=$(date +%s)
    kernel_uninstall "$target" "$reboot" "$remote" "$uninstall" "$flag"
    end=$(date +%s)

    runtime=$((end - start))
    statistics_manager "uninstall" "$runtime"
    return "$?"
  fi

  if ! is_kernel_root "$PWD"; then
    complain "Execute this command in a kernel tree."
    exit 125 # ECANCELED
  fi

  signal_manager 'interrupt_cleanup' || warning 'Was not able to set signal handler'

  if [[ "$target" == "$VM_TARGET" ]]; then
    vm_mount
    ret="$?"
    if [[ "$ret" != 0 ]]; then
      complain "Please shutdown or umount your VM to continue."
      exit "$ret"
    fi
  fi

  # NOTE: If we deploy a new kernel image that does not match with the modules,
  # we can break the boot. For security reason, every time we want to deploy a
  # new kernel version we also update all modules; maybe one day we can change
  # it, but for now this looks the safe option.
  start=$(date +%s)
  modules_install "" "$target" "$remote"
  end=$(date +%s)
  runtime=$((end - start))

  if [[ "$modules" == 0 ]]; then
    start=$(date +%s)
    # Update name: release + alias
    name=$(make kernelrelease)

    kernel_install "$reboot" "$name" "" "$target" "$remote"
    end=$(date +%s)
    runtime=$((runtime + (end - start)))
    statistics_manager "deploy" "$runtime"
  else
    statistics_manager "Modules_deploy" "$runtime"
  fi

  if [[ "$target" == "$VM_TARGET" ]]; then
    # Umount VM if it remains mounted
    vm_umount
  fi

  if [[ "$target" == "$REMOTE_TARGET" ]]; then
    say "Cleanup temporary files"
    cleanup_after_deploy
  fi
}

function deploy_help()
{
  echo -e "kw deploy|d installs kernel and modules:\n" \
    "\tdeploy,d [--remote [REMOTE:PORT]|--local|--vm] [--reboot|-r] [--modules|-m]\n" \
    "\tdeploy,d [--remote [REMOTE:PORT]|--local|--vm] [--uninstall|-u KERNEL_NAME]\n" \
    "\tdeploy,d [--remote [REMOTE:PORT]|--local|--vm] [--ls-line|-s] [--list|-l]"
}

# Populate remote info
#
# @parameters: Command line parameter to be parsed
#
# Returns:
# This function populates the variables REMOTE_IP and REMOTE_PORT based on the
# config file or command line. If it cannot retrieve those data, it returns 22.
function populate_remote_info()
{
  local ip="$1"
  local port

  if [[ -z "$ip" ]]; then
    options_values['REMOTE_IP']=${configurations[ssh_ip]}
    options_values['REMOTE_PORT']=${configurations[ssh_port]}
  else
    temp_ip=$(get_based_on_delimiter "$ip" ":" 1)
    # 22 in the conditon refers to EINVAL
    if [[ "$?" == 22 ]]; then
      options_values['REMOTE_IP']="$ip"
      options_values['REMOTE_PORT']=22
    else
      port=$(get_based_on_delimiter "$ip" ":" 2)
      options_values['REMOTE_IP']="$temp_ip"
      options_values['REMOTE_PORT']="$port"
    fi
  fi

  ip="${options_values['REMOTE_IP']}:${options_values['REMOTE_PORT']}"
  options_values['REMOTE']="$ip"

  if [[ -z "$ip" || "$ip" =~ ^: ]]; then
    complain 'Something went wrong with the remote option'
    return 22 # EINVAL
  fi

  return 0
}

# This function gets raw data and based on that fill out the options values to
# be used in another function.
#
# @raw_options String with all user options
#
# Return:
# In case of successful return 0, otherwise, return 22.
#
function deploy_parser_options()
{
  local raw_options="$*"
  local uninstall=0
  local enable_collect_param=0
  local remote

  options_values["UNINSTALL"]=""
  options_values["MODULES"]=0
  options_values["LS_LINE"]=0
  options_values["LS"]=0
  options_values["REBOOT"]=0
  options_values["MENU_CONFIG"]="nconfig"
  options_values['REMOTE']=''
  options_values['REMOTE_IP']=''
  options_values['REMOTE_PORT']=''

  # Set basic default values
  if [[ -n ${configurations[default_deploy_target]} ]]; then
    local config_file_deploy_target=${configurations[default_deploy_target]}
    options_values["TARGET"]=${deploy_target_opt[$config_file_deploy_target]}
  else
    options_values["TARGET"]="$VM_TARGET"
  fi

  populate_remote_info ''
  if [[ "$?" == 22 ]]; then
    options_values["ERROR"]="$remote"
    return 22 # EINVAL
  fi

  if [[ ${configurations[reboot_after_deploy]} == "yes" ]]; then
    options_values["REBOOT"]=1
  fi

  IFS=' ' read -r -a options <<< "$raw_options"
  for option in "${options[@]}"; do
    if [[ "$option" =~ ^(--.*|-.*|test_mode) ]]; then
      if [[ "$enable_collect_param" == 1 ]]; then
        options_values["ERROR"]="expected paramater"
        return 22
      fi

      case "$option" in
        --remote)
          options_values["TARGET"]="$REMOTE_TARGET"
          continue
          ;;
        --local)
          options_values["TARGET"]="$LOCAL_TARGET"
          continue
          ;;
        --vm)
          options_values["TARGET"]="$VM_TARGET"
          continue
          ;;
        --reboot | -r)
          options_values["REBOOT"]=1
          continue
          ;;
        --modules | -m)
          options_values["MODULES"]=1
          continue
          ;;
        --list | -l)
          options_values["LS"]=1
          continue
          ;;
        --ls-line | -s)
          options_values["LS_LINE"]=1
          continue
          ;;
        --uninstall | -u)
          enable_collect_param=1
          uninstall=1
          continue
          ;;
        test_mode)
          options_values["TEST_MODE"]="TEST_MODE"
          ;;
        *)
          options_values["ERROR"]="$option"
          return 22 # EINVAL
          ;;
      esac
    else # Handle potential parameters
      if [[ "$uninstall" != 1 &&
        ${options_values["TARGET"]} == "$REMOTE_TARGET" ]]; then
        populate_remote_info "$option"
        if [[ "$?" == 22 ]]; then
          options_values["ERROR"]="$option"
          return 22
        fi
      elif [[ "$uninstall" == 1 ]]; then
        options_values["UNINSTALL"]+="$option"
        enable_collect_param=0
      else
        # Invalind option
        options_values["ERROR"]="$option"
        return 22
      fi
    fi
  done

  # Uninstall requires an option
  if [[ "$uninstall" == 1 && -z "${options_values["UNINSTALL"]}" ]]; then
    options_values["ERROR"]="uninstall requires a kernel name"
    return 22
  fi

  case "${options_values["TARGET"]}" in
    1 | 2 | 3) ;;

    *)
      options_values["ERROR"]="remote option"
      return 22
      ;;
  esac
}
