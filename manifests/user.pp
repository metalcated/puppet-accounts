# ==============================
# SHOULD NOT BE CALLED DIRECTLY!
# ==============================
# Always include main class definition:
#
#  class{ '::accounts': }
#
# or with pure YAML declaration, site.pp:
#
#  hiera_include('classes')
#
# hiera configuration e.g. default.yaml:
#   classes:
#     - '::accounts'
#   accounts::users:
#     myuser:
#       groups: ['users']
#
# Linux user account
#
#  Parameters:
#
#  * [allowdupe] - Whether to allow duplicate UIDs. Defaults to false.
#  * [comment] - A description of the user. Generally the user's full name.
#  * [uid] - Force User ID (in Linux)
#  * [gid] - Force Group ID
#  * [manage_group] - Whether primary group with the same name as
#                    the account name should be created
#  * [primary_group] - name of user's primary group, if empty account name
#                    wikk be used.
#
define accounts::user(
  $uid = undef,
  $gid = undef,
  $primary_group = undef,
  $comment = undef,
  # intentionally, workaround for: https://tickets.puppetlabs.com/browse/PUP-4332
  # lint:ignore:only_variable_string  # see https://github.com/deric/puppet-accounts/pull/11 for more details
  $username = "${title}", # lint:ignore:only_variable_string
  $groups = [],
  $ssh_key_source = undef,
  $ssh_key = '',
  $ssh_keys = {},
  $purge_ssh_keys = false,
  $shell ='/bin/bash',
  $pwhash = '',
  $password = undef,
  $salt = undef,
  $hash = 'SHA-512',
  $managehome = true,
  $manage_group = true, # create a group with '$primary_group' name
  $manageumask = false,
  $umask = '0022',
  $home = undef,
  $ensure = present,
  $recurse_permissions = false,
  $authorized_keys_file = undef,
  $force_removal = true,
  $populate_home = false,
  $home_directory_contents = 'puppet:///modules/accounts',
  $password_max_age = undef,
  $allowdupe = false,
  $home_permissions = '0700',
) {

  validate_re($ensure, [ '^absent$', '^present$' ],
    'The $ensure parameter must be \'absent\' or \'present\'')
  validate_hash($ssh_keys)
  validate_bool($managehome)
  if ! is_array($purge_ssh_keys) {
    validate_bool($purge_ssh_keys)
  }

  validate_string($password)
  if $pwhash != '' and $password {
    fail("You cannot set both \$pwhash and \$password for ${username}.")
  }
  if $password {
    if $salt {
      validate_string($salt)
    } else {
      fail('You need to specify a salt for hashing cleartext passwords.')
    }
    if $hash {
      validate_string($hash)
    } else {
      fail('You need to specify a hash function for hashing cleartext passwords.')
    }
  }

  if ($gid) {
    $real_gid = $gid
  } else {
    if $ensure == 'present' and $manage_group == true {
      # choose first non empty argument
      $real_gid = pick($primary_group, $username)
    } else {
      # see https://github.com/deric/puppet-accounts/issues/41
      $real_gid = undef
    }
  }

  if $home {
    $home_dir = $home
  } else {
    $home_dir = $username ? {
      'root'  => '/root',
      default => "/home/${username}",
    }
  }

  User<| title == $username |> {
    gid        => $real_gid,
    comment    => $comment,
    managehome => $managehome,
    home       => $home_dir,
  }

  case $ensure {
    'absent': {
      if $managehome == true {
        exec { "rm -rf ${home_dir}":
          path   => [ '/bin', '/usr/bin' ],
          onlyif => "test -d ${home_dir}",
        }
      }

      anchor { "accounts::user::remove_${name}": }

      # when user is logged in we couldn't remove the account, issue #23
      if $force_removal {
        exec { "killproc ${name}":
          command     => "pkill -TERM -u ${name}; sleep 1; skill -KILL -u ${name}",
          path        => ['/bin', '/sbin', '/usr/bin', '/usr/sbin'],
          onlyif      => "id ${name}",
          refreshonly => true,
          before      => Anchor["accounts::user::remove_${name}"],
        }
      }

      user { $username:
        ensure  => absent,
        uid     => $uid,
        require => Anchor["accounts::user::remove_${name}"],
      }

      if $manage_group == true {
        $pg_name = $primary_group ? {
          undef   => $username,
          default => $primary_group
        }
        group { $pg_name:
          ensure  => absent,
          gid     => $real_gid,
          require => User[$username],
        }
      }
    }
    'present': {
      # prior to Puppet 3.6 `purge_ssh_keys` is not supported
      if versioncmp($::puppetversion, '3.6.0') >= 0 {
        User<| title == $username |> {
          purge_ssh_keys   => $purge_ssh_keys,
          password_max_age => $password_max_age,
        }
      }

      user { $username:
        ensure    => present,
        uid       => $uid,
        shell     => $shell,
        allowdupe => $allowdupe,
      }

      # Set password if available
      if $pwhash != '' {
        User<| title == $username |> { password => $pwhash }
      }
      # Work on cleartext password if available
      if $password {
        $pwh = pw_hash($password, $hash, $salt)
        User<| title == $username |> { password => $pwh }
      }

      if $managehome == true {
        if $populate_home == true {
          file { $home_dir:
            ensure  => directory,
            owner   => $username,
            group   => $real_gid,
            recurse => 'remote',
            mode    => $home_permissions,
            source  => "${home_directory_contents}/${username}",
          }
        }
        else {
          file { $home_dir:
            ensure  => directory,
            owner   => $username,
            group   => $real_gid,
            recurse => $recurse_permissions,
            mode    => $home_permissions,
          }
        }

        # see https://github.com/deric/puppet-accounts/pull/44
        if $manageumask == true {
          file_line { "umask_line_profile_${username}":
            ensure  => present,
            path    => "${home_dir}/.bash_profile",
            line    => "umask ${umask}",
            match   => '^umask \+[0-9][0-9][0-9]',
            require => File[$home_dir],
          } ->
          file_line { "umask_line_bashrc_${username}":
            ensure => present,
            path   => "${home_dir}/.bashrc",
            line   => "umask ${umask}",
            match  => '^umask \+[0-9][0-9][0-9]',
          }
        }

        accounts::authorized_keys { $username:
          real_gid             => $real_gid,
          ssh_key              => $ssh_key,
          ssh_keys             => $ssh_keys,
          ssh_key_source       => $ssh_key_source,
          authorized_keys_file => $authorized_keys_file,
          home_dir             => $home_dir,
          purge_ssh_keys       => $purge_ssh_keys,
          require              => File[$home_dir],
        }
      }

    }
    # other ensure value is not possible (exception would be thrown earlier)
    default: {}
  }
}
