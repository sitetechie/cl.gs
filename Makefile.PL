use strict;
use warnings;

use inc::Module::Install;

name            'cl.gs';
all_from        'lib/clgs.pm';
homepage        'http://cl.gs/';
readme_from;

author_requires 'Module::Install::AuthorRequires';
author_requires 'Module::Install::AutoManifest';
author_requires 'Module::Install::AutoLicense';
author_requires 'Module::Install::AuthorTests';
author_requires 'Module::Install::ReadmeFromPod';
author_requires 'Module::Install::ExtraTests';
author_requires 'Module::Install::ManifestSkip';
author_requires 'Module::Install::GithubMeta';
author_requires 'Module::Install::Repository';
author_requires 'Module::Install::VersionCheck';

author_requires 'Test::Pod'             => '1.14';
author_requires 'Test::Pod::Coverage';
author_requires 'Pod::Coverage::Moose';
author_requires 'Test::Perl::Critic'    => '1.02';
author_requires 'Perl::Critic'          => '1.11';

requires 'JSON';
requires 'URI';
requires 'Template'                  => '2.22';
requires 'Const::Fast'               => '0.011';
requires 'namespace::autoclean'      => '0.13';
requires 'Moose'                     => '2.0403';
requires 'MooseX::StrictConstructor' => '0.19';
requires 'DateTime'                  => '0.66';
requires 'String::Koremutake'        => '0.30';
requires 'Data::Validate::URI'       => '0.06';
requires 'Dancer'                    => '1.3093';
requires 'Redis'                     => '1.904';
requires 'Dancer::Plugin::Redis'     => '0.02';

test_requires 'Test::Fatal';
test_requires 'Test::Exception';
test_requires 'Test::Moose::More';
test_requires 'Test::MockTime';
test_requires 'Test::Script'         => '1.05';

author_tests    'xt';

manifest_skip;
auto_set_repository;
auto_manifest;
auto_license;
auto_include;
version_check;

auto_include_deps;
auto_install;
WriteAll;

