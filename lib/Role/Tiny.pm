package Role::Tiny;
use strict;
use warnings;

our $VERSION = '2.000_009';
$VERSION =~ tr/_//d;

our %INFO;
our %APPLIED_TO;
our %COMPOSED;
our %COMPOSITE_INFO;
our @ON_ROLE_CREATE;

# Module state workaround totally stolen from Zefram's Module::Runtime.

BEGIN {
  *_WORK_AROUND_BROKEN_MODULE_STATE = "$]" < 5.009 ? sub(){1} : sub(){0};
  *_WORK_AROUND_HINT_LEAKAGE
    = "$]" < 5.011 && !("$]" >= 5.009004 && "$]" < 5.010001)
      ? sub(){1} : sub(){0};
  *_MRO_MODULE = "$]" < 5.010 ? sub(){"MRO/Compat.pm"} : sub(){"mro.pm"};
}

sub _getglob { no strict 'refs'; \*{$_[0]} }
sub _getstash { no strict 'refs'; \%{"$_[0]::"} }

sub croak {
  require Carp;
  no warnings 'redefine';
  *croak = \&Carp::croak;
  goto &Carp::croak;
}

sub Role::Tiny::__GUARD__::DESTROY {
  delete $INC{$_[0]->[0]} if @{$_[0]};
}

sub _load_module {
  my ($module) = @_;
  (my $file = "$module.pm") =~ s{::}{/}g;
  return 1
    if $INC{$file};

  # can't just ->can('can') because a sub-package Foo::Bar::Baz
  # creates a 'Baz::' key in Foo::Bar's symbol table
  return 1
    if grep !/::\z/, keys %{_getstash($module)};
  my $guard = _WORK_AROUND_BROKEN_MODULE_STATE
    && bless([ $file ], 'Role::Tiny::__GUARD__');
  local %^H if _WORK_AROUND_HINT_LEAKAGE;
  require $file;
  pop @$guard if _WORK_AROUND_BROKEN_MODULE_STATE;
  return 1;
}

sub _all_subs {
  my ($me, $package) = @_;
  my $stash = _getstash($package);
  return {
    map +($_ => \&{"${package}::${_}"}),
    grep exists &{"${package}::${_}"},
    grep !/::\z/,
    keys %$stash
  };
}

sub import {
  my $target = caller;
  my $me = shift;
  strict->import;
  warnings->import;
  $me->_install_subs($target, @_);
  $me->make_role($target);
  return;
}

sub make_role {
  my ($me, $target) = @_;

  return if $me->is_role($target);
  $INFO{$target}{is_role} = 1;

  my $non_methods = $me->_all_subs($target);
  delete @{$non_methods}{grep /\A\(/, keys %$non_methods};
  $INFO{$target}{non_methods} = $non_methods;

  # a role does itself
  $APPLIED_TO{$target} = { $target => undef };
  foreach my $hook (@ON_ROLE_CREATE) {
    $hook->($target);
  }
}

sub _install_subs {
  my ($me, $target) = @_;
  my %install = $me->_gen_subs($target);
  *{_getglob("${target}::${_}")} = $install{$_}
    for sort keys %install;
  return;
}

sub _gen_subs {
  my ($me, $target) = @_;
  (
    (map {;
      my $type = $_;
      $type => sub {
        push @{$INFO{$target}{modifiers}||=[]}, [ $type => @_ ];
        return;
      };
    } qw(before after around)),
    requires => sub {
      push @{$INFO{$target}{requires}||=[]}, @_;
      return;
    },
    with => sub {
      $me->apply_roles_to_package($target, @_);
      return;
    },
  );
}

sub role_application_steps {
  qw(_install_methods _check_requires _install_modifiers _copy_applied_list);
}

sub apply_single_role_to_package {
  my ($me, $to, $role) = @_;

  _load_module($role);

  croak "This is apply_role_to_package" if ref($to);
  croak "${role} is not a Role::Tiny" unless $me->is_role($role);

  foreach my $step ($me->role_application_steps) {
    $me->$step($to, $role);
  }
}

sub _copy_applied_list {
  my ($me, $to, $role) = @_;
  # copy our role list into the target's
  @{$APPLIED_TO{$to}||={}}{keys %{$APPLIED_TO{$role}}} = ();
}

sub apply_roles_to_object {
  my ($me, $object, @roles) = @_;
  croak "No roles supplied!" unless @roles;
  my $class = ref($object);
  # on perl < 5.8.9, magic isn't copied to all ref copies. bless the parameter
  # directly, so at least the variable passed to us will get any magic applied
  bless($_[1], $me->create_class_with_roles($class, @roles));
}

my $role_suffix = 'A000';
sub _composite_name {
  my ($me, $superclass, @roles) = @_;

  my $new_name = join(
    '__WITH__', $superclass, my $compose_name = join '__AND__', @roles
  );

  if (length($new_name) > 252) {
    $new_name = $COMPOSED{abbrev}{$new_name} ||= do {
      my $abbrev = substr $new_name, 0, 250 - length $role_suffix;
      $abbrev =~ s/(?<!:):$//;
      $abbrev.'__'.$role_suffix++;
    };
  }
  return wantarray ? ($new_name, $compose_name) : $new_name;
}

sub create_class_with_roles {
  my ($me, $superclass, @roles) = @_;

  croak "No roles supplied!" unless @roles;

  _load_module($superclass);
  {
    my %seen;
    if (my @dupes = grep 1 == $seen{$_}++, @roles) {
      croak "Duplicated roles: ".join(', ', @dupes);
    }
  }

  my ($new_name, $compose_name) = $me->_composite_name($superclass, @roles);

  return $new_name if $COMPOSED{class}{$new_name};

  foreach my $role (@roles) {
    _load_module($role);
    croak "${role} is not a Role::Tiny" unless $me->is_role($role);
  }

  require(_MRO_MODULE);

  my $composite_info = $me->_composite_info_for(@roles);
  my %conflicts = %{$composite_info->{conflicts}};
  if (keys %conflicts) {
    my $fail =
      join "\n",
        map {
          "Method name conflict for '$_' between roles "
          ."'".join("' and '", sort values %{$conflicts{$_}})."'"
          .", cannot apply these simultaneously to an object."
        } keys %conflicts;
    croak $fail;
  }

  my @composable = map $me->_composable_package_for($_), reverse @roles;

  # some methods may not exist in the role, but get generated by
  # _composable_package_for (Moose accessors via Moo).  filter out anything
  # provided by the composable packages, excluding the subs we generated to
  # make modifiers work.
  my @requires = grep {
    my $method = $_;
    !grep $_->can($method) && !$COMPOSED{role}{$_}{modifiers_only}{$method},
      @composable
  } @{$composite_info->{requires}};

  $me->_check_requires(
    $superclass, $compose_name, \@requires
  );

  *{_getglob("${new_name}::ISA")} = [ @composable, $superclass ];

  @{$APPLIED_TO{$new_name}||={}}{
    map keys %{$APPLIED_TO{$_}}, @roles
  } = ();

  $COMPOSED{class}{$new_name} = 1;
  return $new_name;
}

# preserved for compat, and apply_roles_to_package calls it to allow an
# updated Role::Tiny to use a non-updated Moo::Role

sub apply_role_to_package { shift->apply_single_role_to_package(@_) }

sub apply_roles_to_package {
  my ($me, $to, @roles) = @_;

  return $me->apply_role_to_package($to, $roles[0]) if @roles == 1;

  my %conflicts = %{$me->_composite_info_for(@roles)->{conflicts}};
  my @have = grep $to->can($_), keys %conflicts;
  delete @conflicts{@have};

  if (keys %conflicts) {
    my $fail =
      join "\n",
        map {
          "Due to a method name conflict between roles "
          ."'".join(' and ', sort values %{$conflicts{$_}})."'"
          .", the method '$_' must be implemented by '${to}'"
        } keys %conflicts;
    croak $fail;
  }

  # conflicting methods are supposed to be treated as required by the
  # composed role. we don't have an actual composed role, but because
  # we know the target class already provides them, we can instead
  # pretend that the roles don't do for the duration of application.
  my @role_methods = map $me->_concrete_methods_of($_), @roles;
  # separate loops, since local ..., delete ... for ...; creates a scope
  local @{$_}{@have} for @role_methods;
  delete @{$_}{@have} for @role_methods;

  # the if guard here is essential since otherwise we accidentally create
  # a $INFO for something that isn't a Role::Tiny (or Moo::Role) because
  # autovivification hates us and wants us to die()
  if ($INFO{$to}) {
    delete $INFO{$to}{methods}; # reset since we're about to add methods
  }

  # backcompat: allow subclasses to use apply_single_role_to_package
  # to apply changes.  set a local var so ours does nothing.
  our %BACKCOMPAT_HACK;
  if($me ne __PACKAGE__
      and exists $BACKCOMPAT_HACK{$me} ? $BACKCOMPAT_HACK{$me} :
      $BACKCOMPAT_HACK{$me} =
        $me->can('role_application_steps')
          == \&role_application_steps
        && $me->can('apply_single_role_to_package')
          != \&apply_single_role_to_package
  ) {
    foreach my $role (@roles) {
      $me->apply_single_role_to_package($to, $role);
    }
  }
  else {
    foreach my $step ($me->role_application_steps) {
      foreach my $role (@roles) {
        $me->$step($to, $role);
      }
    }
  }
  $APPLIED_TO{$to}{join('|',@roles)} = 1;
}

sub _composite_info_for {
  my ($me, @roles) = @_;
  $COMPOSITE_INFO{join('|', sort @roles)} ||= do {
    foreach my $role (@roles) {
      _load_module($role);
    }
    my %methods;
    foreach my $role (@roles) {
      my $this_methods = $me->_concrete_methods_of($role);
      $methods{$_}{$this_methods->{$_}} = $role for keys %$this_methods;
    }
    my %requires;
    @requires{map @{$INFO{$_}{requires}||[]}, @roles} = ();
    delete $requires{$_} for keys %methods;
    delete $methods{$_} for grep keys(%{$methods{$_}}) == 1, keys %methods;
    +{ conflicts => \%methods, requires => [keys %requires] }
  };
}

sub _composable_package_for {
  my ($me, $role) = @_;
  my $composed_name = 'Role::Tiny::_COMPOSABLE::'.$role;
  return $composed_name if $COMPOSED{role}{$composed_name};
  $me->_install_methods($composed_name, $role);
  my $base_name = $composed_name.'::_BASE';
  # force stash to exist so ->can doesn't complain
  _getstash($base_name);
  # Not using _getglob, since setting @ISA via the typeglob breaks
  # inheritance on 5.10.0 if the stash has previously been accessed an
  # then a method called on the class (in that order!), which
  # ->_install_methods (with the help of ->_install_does) ends up doing.
  { no strict 'refs'; @{"${composed_name}::ISA"} = ( $base_name ); }
  my $modifiers = $INFO{$role}{modifiers}||[];
  my @mod_base;
  my @modifiers = grep !$composed_name->can($_),
    do { my %h; @h{map @{$_}[1..$#$_-1], @$modifiers} = (); keys %h };
  foreach my $modified (@modifiers) {
    push @mod_base, "sub ${modified} { shift->next::method(\@_) }";
  }
  my $e;
  {
    local $@;
    eval(my $code = join "\n", "package ${base_name};", @mod_base);
    $e = "Evaling failed: $@\nTrying to eval:\n${code}" if $@;
  }
  die $e if $e;
  $me->_install_modifiers($composed_name, $role);
  $COMPOSED{role}{$composed_name} = {
    modifiers_only => { map { $_ => 1 } @modifiers },
  };
  return $composed_name;
}

sub _check_requires {
  my ($me, $to, $name, $requires) = @_;
  return unless my @requires = @{$requires||$INFO{$name}{requires}||[]};
  if (my @requires_fail = grep !$to->can($_), @requires) {
    # role -> role, add to requires, role -> class, error out
    if (my $to_info = $INFO{$to}) {
      push @{$to_info->{requires}||=[]}, @requires_fail;
    } else {
      croak "Can't apply ${name} to ${to} - missing ".join(', ', @requires_fail);
    }
  }
}

sub _non_methods {
  my ($me, $role) = @_;
  my $info = $INFO{$role} or return {};

  my %non_methods = %{ $info->{non_methods} || {} };

  # this is only for backwards compatibility with older Moo, which
  # reimplements method tracking rather than calling our method
  my %not_methods = reverse %{ $info->{not_methods} || {} };
  return \%non_methods unless keys %not_methods;

  my $subs = $me->_all_subs($role);
  for my $sub (grep !/\A\(/, keys %$subs) {
    my $code = $subs->{$sub};
    if (exists $not_methods{$code}) {
      $non_methods{$sub} = $code;
    }
  }

  return \%non_methods;
}

sub _concrete_methods_of {
  my ($me, $role) = @_;
  my $info = $INFO{$role};

  return $info->{methods}
    if $info && $info->{methods};

  my $non_methods = $me->_non_methods($role);

  my $subs = $me->_all_subs($role);
  for my $sub (keys %$subs) {
    if ( exists $non_methods->{$sub} && $non_methods->{$sub} == $subs->{$sub} ) {
      delete $subs->{$sub};
    }
  }

  if ($info) {
    $info->{methods} = $subs;
  }
  return $subs;
}

sub methods_provided_by {
  my ($me, $role) = @_;
  croak "${role} is not a Role::Tiny" unless $me->is_role($role);
  sort (keys %{$me->_concrete_methods_of($role)}, @{$INFO{$role}->{requires}||[]});
}

sub _install_methods {
  my ($me, $to, $role) = @_;

  my $info = $INFO{$role};

  my $methods = $me->_concrete_methods_of($role);

  # grab target symbol table
  my $stash = _getstash($to);

  foreach my $i (keys %$methods) {
    my $target = $stash->{$i};

    no warnings 'once';
    no strict 'refs';

    next
      if exists &{"${to}::${i}"};

    my $glob = _getglob "${to}::${i}";
    *$glob = $methods->{$i};

    # overloads using method names have the method stored in the scalar slot
    # and &overload::nil in the code slot.
    next
      unless $i =~ /^\(/
        && ((defined &overload::nil && $methods->{$i} == \&overload::nil)
            || (defined &overload::_nil && $methods->{$i} == \&overload::_nil));

    my $overload = ${ _getglob "${role}::${i}" };
    next
      unless defined $overload;

    *$glob = \$overload;
  }

  $me->_install_does($to);
}

sub _install_modifiers {
  my ($me, $to, $name) = @_;
  return unless my $modifiers = $INFO{$name}{modifiers};
  my $info = $INFO{$to};
  my $existing = ($info ? $info->{modifiers} : $COMPOSED{modifiers}{$to}) ||= [];
  my @modifiers = grep {
    my $modifier = $_;
    !grep $_ == $modifier, @$existing;
  } @{$modifiers||[]};
  push @$existing, @modifiers;

  if (!$info) {
    foreach my $modifier (@modifiers) {
      $me->_install_single_modifier($to, @$modifier);
    }
  }
}

my $vcheck_error;

sub _install_single_modifier {
  my ($me, @args) = @_;
  defined($vcheck_error) or $vcheck_error = do {
    local $@;
    eval {
      require Class::Method::Modifiers;
      Class::Method::Modifiers->VERSION(1.05);
      1;
    } ? 0 : $@;
  };
  $vcheck_error and die $vcheck_error;
  Class::Method::Modifiers::install_modifier(@args);
}

my $FALLBACK = sub { 0 };
sub _install_does {
  my ($me, $to) = @_;

  # only add does() method to classes
  return if $me->is_role($to);

  my $does = $me->can('does_role');
  # add does() only if they don't have one
  *{_getglob "${to}::does"} = $does unless $to->can('does');

  return
    if $to->can('DOES') and $to->can('DOES') != (UNIVERSAL->can('DOES') || 0);

  my $existing = $to->can('DOES') || $to->can('isa') || $FALLBACK;
  my $new_sub = sub {
    my ($proto, $role) = @_;
    $proto->$does($role) or $proto->$existing($role);
  };
  no warnings 'redefine';
  return *{_getglob "${to}::DOES"} = $new_sub;
}

sub does_role {
  my ($proto, $role) = @_;
  require(_MRO_MODULE);
  foreach my $class (@{mro::get_linear_isa(ref($proto)||$proto)}) {
    return 1 if exists $APPLIED_TO{$class}{$role};
  }
  return 0;
}

sub is_role {
  my ($me, $role) = @_;
  return !!($INFO{$role} && ($INFO{$role}{is_role} || $INFO{$role}{not_methods} || $INFO{$role}{non_methods}));
}

1;
__END__

=encoding utf-8

=head1 NAME

Role::Tiny - Roles: a nouvelle cuisine portion size slice of Moose

=head1 SYNOPSIS

 package Some::Role;

 use Role::Tiny;

 sub foo { ... }

 sub bar { ... }

 around baz => sub { ... };

 1;

elsewhere

 package Some::Class;

 use Role::Tiny::With;

 # bar gets imported, but not foo
 with 'Some::Role';

 sub foo { ... }

 # baz is wrapped in the around modifier by Class::Method::Modifiers
 sub baz { ... }

 1;

If you wanted attributes as well, look at L<Moo::Role>.

=head1 DESCRIPTION

C<Role::Tiny> is a minimalist role composition tool.

=head1 ROLE COMPOSITION

Role composition can be thought of as much more clever and meaningful multiple
inheritance.  The basics of this implementation of roles is:

=over 2

=item *

If a method is already defined on a class, that method will not be composed in
from the role. A method inherited by a class gets overridden by the role's
method of the same name, though.

=item *

If a method that the role L</requires> to be implemented is not implemented,
role application will fail loudly.

=back

Unlike L<Class::C3>, where the B<last> class inherited from "wins," role
composition is the other way around, where the class wins. If multiple roles
are applied in a single call (single with statement), then if any of their
provided methods clash, an exception is raised unless the class provides
a method since this conflict indicates a potential problem.

=head1 IMPORTED SUBROUTINES

=head2 requires

 requires qw(foo bar);

Declares a list of methods that must be defined to compose role.

=head2 with

 with 'Some::Role1';

 with 'Some::Role1', 'Some::Role2';

Composes another role into the current role (or class via L<Role::Tiny::With>).

If you have conflicts and want to resolve them in favour of Some::Role1 you
can instead write:

 with 'Some::Role1';
 with 'Some::Role2';

If you have conflicts and want to resolve different conflicts in favour of
different roles, please refactor your codebase.

=head2 before

 before foo => sub { ... };

See L<< Class::Method::Modifiers/before method(s) => sub { ... } >> for full
documentation.

Note that since you are not required to use method modifiers,
L<Class::Method::Modifiers> is lazily loaded and we do not declare it as
a dependency. If your L<Role::Tiny> role uses modifiers you must depend on
both L<Class::Method::Modifiers> and L<Role::Tiny>.

=head2 around

 around foo => sub { ... };

See L<< Class::Method::Modifiers/around method(s) => sub { ... } >> for full
documentation.

Note that since you are not required to use method modifiers,
L<Class::Method::Modifiers> is lazily loaded and we do not declare it as
a dependency. If your L<Role::Tiny> role uses modifiers you must depend on
both L<Class::Method::Modifiers> and L<Role::Tiny>.

=head2 after

 after foo => sub { ... };

See L<< Class::Method::Modifiers/after method(s) => sub { ... } >> for full
documentation.

Note that since you are not required to use method modifiers,
L<Class::Method::Modifiers> is lazily loaded and we do not declare it as
a dependency. If your L<Role::Tiny> role uses modifiers you must depend on
both L<Class::Method::Modifiers> and L<Role::Tiny>.

=head2 Strict and Warnings

In addition to importing subroutines, using C<Role::Tiny> applies L<strict> and
L<warnings> to the caller.

=head1 SUBROUTINES

=head2 does_role

 if (Role::Tiny::does_role($foo, 'Some::Role')) {
   ...
 }

Returns true if class has been composed with role.

This subroutine is also installed as ->does on any class a Role::Tiny is
composed into unless that class already has an ->does method, so

  if ($foo->does('Some::Role')) {
    ...
  }

will work for classes but to test a role, one must use ::does_role directly.

Additionally, Role::Tiny will override the standard Perl C<DOES> method
for your class. However, if C<any> class in your class' inheritance
hierarchy provides C<DOES>, then Role::Tiny will not override it.

=head1 METHODS

=head2 apply_roles_to_package

 Role::Tiny->apply_roles_to_package(
   'Some::Package', 'Some::Role', 'Some::Other::Role'
 );

Composes role with package.  See also L<Role::Tiny::With>.

=head2 apply_roles_to_object

 Role::Tiny->apply_roles_to_object($foo, qw(Some::Role1 Some::Role2));

Composes roles in order into object directly. Object is reblessed into the
resulting class. Note that the object's methods get overridden by the role's
ones with the same names.

=head2 create_class_with_roles

 Role::Tiny->create_class_with_roles('Some::Base', qw(Some::Role1 Some::Role2));

Creates a new class based on base, with the roles composed into it in order.
New class is returned.

=head2 is_role

 Role::Tiny->is_role('Some::Role1')

Returns true if the given package is a role.

=head1 CAVEATS

=over 4

=item * On perl 5.8.8 and earlier, applying a role to an object won't apply any
overloads from the role to other copies of the object.

=item * On perl 5.16 and earlier, applying a role to a class won't apply any
overloads from the role to any existing instances of the class.

=back

=head1 SEE ALSO

L<Role::Tiny> is the attribute-less subset of L<Moo::Role>; L<Moo::Role> is
a meta-protocol-less subset of the king of role systems, L<Moose::Role>.

Ovid's L<Role::Basic> provides roles with a similar scope, but without method
modifiers, and having some extra usage restrictions.

=head1 AUTHOR

mst - Matt S. Trout (cpan:MSTROUT) <mst@shadowcat.co.uk>

=head1 CONTRIBUTORS

dg - David Leadbeater (cpan:DGL) <dgl@dgl.cx>

frew - Arthur Axel "fREW" Schmidt (cpan:FREW) <frioux@gmail.com>

hobbs - Andrew Rodland (cpan:ARODLAND) <arodland@cpan.org>

jnap - John Napiorkowski (cpan:JJNAPIORK) <jjn1056@yahoo.com>

ribasushi - Peter Rabbitson (cpan:RIBASUSHI) <ribasushi@cpan.org>

chip - Chip Salzenberg (cpan:CHIPS) <chip@pobox.com>

ajgb - Alex J. G. Burzyński (cpan:AJGB) <ajgb@cpan.org>

doy - Jesse Luehrs (cpan:DOY) <doy at tozt dot net>

perigrin - Chris Prather (cpan:PERIGRIN) <chris@prather.org>

Mithaldu - Christian Walde (cpan:MITHALDU) <walde.christian@googlemail.com>

ilmari - Dagfinn Ilmari Mannsåker (cpan:ILMARI) <ilmari@ilmari.org>

tobyink - Toby Inkster (cpan:TOBYINK) <tobyink@cpan.org>

haarg - Graham Knop (cpan:HAARG) <haarg@haarg.org>

=head1 COPYRIGHT

Copyright (c) 2010-2012 the Role::Tiny L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself.

=cut
