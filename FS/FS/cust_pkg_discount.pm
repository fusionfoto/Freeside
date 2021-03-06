package FS::cust_pkg_discount;
use base qw( FS::otaker_Mixin
             FS::cust_main_Mixin
             FS::pkg_discount_Mixin
             FS::Record );

use strict;
use FS::Record qw( dbh ); # qsearch qsearchs dbh );
use FS::discount;

=head1 NAME

FS::cust_pkg_discount - Object methods for cust_pkg_discount records

=head1 SYNOPSIS

  use FS::cust_pkg_discount;

  $record = new FS::cust_pkg_discount \%hash;
  $record = new FS::cust_pkg_discount { 'column' => 'value' };

  $error = $record->insert;

  $error = $new_record->replace($old_record);

  $error = $record->delete;

  $error = $record->check;

=head1 DESCRIPTION

An FS::cust_pkg_discount object represents the application of a discount to a
customer package.  FS::cust_pkg_discount inherits from FS::Record.  The
following fields are currently supported:

=over 4

=item pkgdiscountnum

primary key

=item pkgnum

Customer package (see L<FS::cust_pkg>)

=item discountnum

Discount (see L<FS::discount>)

=item months_used

months_used

=item end_date

end_date

=item usernum

order taker, see L<FS::access_user>

=item setuprecur

whether this discount applies to setup fees or recurring fees

=back

=head1 METHODS

=over 4

=item new HASHREF

Creates a new discount application.  To add the record to the database, see
 L<"insert">.

Note that this stores the hash reference, not a distinct copy of the hash it
points to.  You can ask the object for a copy with the I<hash> method.

=cut

# the new method can be inherited from FS::Record, if a table method is defined

sub table { 'cust_pkg_discount'; }

=item insert

Adds this record to the database.  If there is an error, returns the error,
otherwise returns false.

=item delete

Delete this record from the database.

=cut

# the delete method can be inherited from FS::Record

=item replace OLD_RECORD

Replaces the OLD_RECORD with this one in the database.  If there is an error,
returns the error, otherwise returns false.

=cut

# the replace method can be inherited from FS::Record

=item check

Checks all fields to make sure this is a valid discount applciation.  If there
is an error, returns the error, otherwise returns false.  Called by the insert
and replace methods.

=cut

# the check method should currently be supplied - FS::Record contains some
# data checking routines

sub check {
  my $self = shift;

  my $error = 
    $self->ut_numbern('pkgdiscountnum')
    || $self->ut_foreign_key('pkgnum', 'cust_pkg', 'pkgnum')
    || $self->ut_foreign_key('discountnum', 'discount', 'discountnum' )
    || $self->ut_sfloat('months_used') #actually decimal, but this will do
    || $self->ut_numbern('end_date')
    || $self->ut_alphan('otaker')
    || $self->ut_numbern('usernum')
    || $self->ut_enum('disabled', [ '', 'Y' ] )
    || $self->ut_enum('setuprecur', [ 'setup', 'recur' ] )
  ;
  return $error if $error;

  my $cust_pkg = $self->cust_pkg;
  my $discount = $self->discount;
  if ( $self->setuprecur eq 'setup' ) {
    if ( !$discount->setup ) {
      # UI prevents this, and historical discounts should never have it either
      return "Discount #".$self->discountnum." can't be applied to setup fees.";
    } elsif ( $cust_pkg->base_setup == 0 ) {
      # and this
      return "Can't apply setup discount to a package with no setup fee.";
    }
    # else we're good. do NOT disallow applying setup discounts when the
    # setup date is already set; upgrades use that.
  } else {
    if ( $self->cust_pkg->base_recur == 0 ) {
      return "Can't apply recur discount to a package with no recurring fee.";
    } elsif ( $cust_pkg->part_pkg->freq eq '0' ) {
      return "Can't apply recur discount to a one-time charge.";
    }
  }

  $self->usernum($FS::CurrentUser::CurrentUser->usernum) unless $self->usernum;

  $self->SUPER::check;
}

=item cust_pkg

Returns the customer package (see L<FS::cust_pkg>).

=item discount

Returns the discount (see L<FS::discount>).

=item increment_months_used MONTHS

Increments months_used by the given parameter

=cut

sub increment_months_used {
  my( $self, $used ) = @_;
  #UPDATE cust_pkg_discount SET months_used = months_used + ?
  #leaves no history, and billing is mutexed per-customer, so the dum way is ok
  $self->months_used( $self->months_used + $used );
  $self->replace();
}

=item decrement_months_used MONTHS

Decrement months_used by the given parameter

(Note: as in, extending the length of the discount.  Typically only used to
stack/extend a discount when the customer package has one active already.)

=cut

sub decrement_months_used {
  my( $self, $recharged ) = @_;
  #UPDATE cust_pkg_discount SET months_used = months_used - ?
  #leaves no history, and billing is mutexed per-customer

  #we're run from part_event/Action/referral_pkg_discount on behalf of a
  # different customer, so we need to grab this customer's mutex.
  #   incidentally, that's some inelegant encapsulation breaking shit, and a
  #   great argument in favor of native-DB trigger history so we can trust
  #   in normal ACID like the SQL above instead of this
  $self->cust_pkg->cust_main->select_for_update;

  $self->months_used( $self->months_used - $recharged );
  $self->replace();
}

=item status

=cut

sub status {
  my $self = shift;
  my $discount = $self->discount;

  if ( $self->disabled ne 'Y' 
       and ( ! $discount->months || $self->months_used < $discount->months )
             #XXX also end date
     ) {
    'active';
  } else {
    'expired';
  }
}

# Used by FS::Upgrade to migrate to a new database.
sub _upgrade_data {  # class method
  my ($class, %opts) = @_;
  $class->_upgrade_otaker(%opts);

  # #14092: set setuprecur field on discounts. if we get one that applies to
  # both setup and recur, split it into two discounts.
  my $search = FS::Cursor->new({
      table   => 'cust_pkg_discount',
      hashref => { setuprecur => '' }
  });
  while ( my $cust_pkg_discount = $search->fetch ) {
    my $discount = $cust_pkg_discount->discount;
    my $cust_pkg = $cust_pkg_discount->cust_pkg;
    # 1. Does it apply to the setup fee?
    # Yes, if: the discount applies to setup fees generally, and the package
    # has a setup fee.
    # No, if: the discount is a flat amount, and is not first-month only.
    if ( $discount->setup
        and $cust_pkg->base_setup > 0
        and ($discount->amount == 0 or $discount->months == 1)
       )
    {
      # then clone this discount into a new one
      my $setup_discount = FS::cust_pkg_discount->new({
          $cust_pkg_discount->hash,
          setuprecur      => 'setup',
          pkgdiscountnum  => ''
      });
      my $error = $setup_discount->insert;
      die "$error (migrating cust_pkg_discount to setup discount)" if $error;
    }
    # 2. Does it apply to the recur fee?
    # Yes, if: the package has a recur fee.
    if ( $cust_pkg->base_recur > 0 ) {
      # then modify this discount in place
      $cust_pkg_discount->set('setuprecur' => 'recur');
      my $error = $cust_pkg_discount->replace;
      die "$error (migrating cust_pkg_discount)" if $error;
    }
    # not in here yet: splitting the cust_bill_pkg_discount records.
    # (not really necessary)
  }
}

=back

=head1 BUGS

=head1 SEE ALSO

L<FS::discount>, L<FS::cust_pkg>, L<FS::Record>, schema.html from the base documentation.

=cut

1;

