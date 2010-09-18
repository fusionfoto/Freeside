package FS::cust_main;

require 5.006;
use strict;
use base qw( FS::cust_main::Billing FS::cust_main::Billing_Realtime
             FS::otaker_Mixin FS::payinfo_Mixin FS::cust_main_Mixin
             FS::Record
           );
use vars qw( $DEBUG $me $conf
             @encrypted_fields
             $import
             $ignore_expired_card $ignore_illegal_zip $ignore_banned_card
             $skip_fuzzyfiles @fuzzyfields
             @paytypes
           );
use vars qw( $realtime_bop_decline_quiet ); #ugh
use Carp;
use Scalar::Util qw( blessed );
use List::Util qw( min );
use Time::Local qw(timelocal);
use Storable qw(thaw);
use MIME::Base64;
use Data::Dumper;
use Tie::IxHash;
use Digest::MD5 qw(md5_base64);
use Date::Format;
#use Date::Manip;
use File::Temp qw( tempfile );
use Business::CreditCard 0.28;
use Locale::Country;
use FS::UID qw( getotaker dbh driver_name );
use FS::Record qw( qsearchs qsearch dbdef regexp_sql );
use FS::Misc qw( generate_email send_email generate_ps do_print );
use FS::Msgcat qw(gettext);
use FS::CurrentUser;
use FS::payby;
use FS::cust_pkg;
use FS::cust_svc;
use FS::cust_bill;
use FS::cust_pay;
use FS::cust_pay_pending;
use FS::cust_pay_void;
use FS::cust_pay_batch;
use FS::cust_credit;
use FS::cust_refund;
use FS::part_referral;
use FS::cust_main_county;
use FS::cust_location;
use FS::cust_class;
use FS::cust_main_exemption;
use FS::cust_tax_adjustment;
use FS::cust_tax_location;
use FS::agent;
use FS::cust_main_invoice;
use FS::cust_tag;
use FS::prepay_credit;
use FS::queue;
use FS::part_pkg;
use FS::part_event;
use FS::part_event_condition;
use FS::part_export;
#use FS::cust_event;
use FS::type_pkgs;
use FS::payment_gateway;
use FS::agent_payment_gateway;
use FS::banned_pay;
use FS::TicketSystem;

$realtime_bop_decline_quiet = 0; #move to Billing_Realtime

# 1 is mostly method/subroutine entry and options
# 2 traces progress of some operations
# 3 is even more information including possibly sensitive data
$DEBUG = 0;
$me = '[FS::cust_main]';

$import = 0;
$ignore_expired_card = 0;
$ignore_illegal_zip = 0;
$ignore_banned_card = 0;

$skip_fuzzyfiles = 0;
@fuzzyfields = ( 'first', 'last', 'company', 'address1' );

@encrypted_fields = ('payinfo', 'paycvv');
sub nohistory_fields { ('payinfo', 'paycvv'); }

@paytypes = ('', 'Personal checking', 'Personal savings', 'Business checking', 'Business savings');

#ask FS::UID to run this stuff for us later
#$FS::UID::callback{'FS::cust_main'} = sub { 
install_callback FS::UID sub { 
  $conf = new FS::Conf;
  #yes, need it for stuff below (prolly should be cached)
};

sub _cache {
  my $self = shift;
  my ( $hashref, $cache ) = @_;
  if ( exists $hashref->{'pkgnum'} ) {
    #@{ $self->{'_pkgnum'} } = ();
    my $subcache = $cache->subcache( 'pkgnum', 'cust_pkg', $hashref->{custnum});
    $self->{'_pkgnum'} = $subcache;
    #push @{ $self->{'_pkgnum'} },
    FS::cust_pkg->new_or_cached($hashref, $subcache) if $hashref->{pkgnum};
  }
}

=head1 NAME

FS::cust_main - Object methods for cust_main records

=head1 SYNOPSIS

  use FS::cust_main;

  $record = new FS::cust_main \%hash;
  $record = new FS::cust_main { 'column' => 'value' };

  $error = $record->insert;

  $error = $new_record->replace($old_record);

  $error = $record->delete;

  $error = $record->check;

  @cust_pkg = $record->all_pkgs;

  @cust_pkg = $record->ncancelled_pkgs;

  @cust_pkg = $record->suspended_pkgs;

  $error = $record->bill;
  $error = $record->bill %options;
  $error = $record->bill 'time' => $time;

  $error = $record->collect;
  $error = $record->collect %options;
  $error = $record->collect 'invoice_time'   => $time,
                          ;

=head1 DESCRIPTION

An FS::cust_main object represents a customer.  FS::cust_main inherits from 
FS::Record.  The following fields are currently supported:

=over 4

=item custnum

Primary key (assigned automatically for new customers)

=item agentnum

Agent (see L<FS::agent>)

=item refnum

Advertising source (see L<FS::part_referral>)

=item first

First name

=item last

Last name

=item ss

Cocial security number (optional)

=item company

(optional)

=item address1

=item address2

(optional)

=item city

=item county

(optional, see L<FS::cust_main_county>)

=item state

(see L<FS::cust_main_county>)

=item zip

=item country

(see L<FS::cust_main_county>)

=item daytime

phone (optional)

=item night

phone (optional)

=item fax

phone (optional)

=item ship_first

Shipping first name

=item ship_last

Shipping last name

=item ship_company

(optional)

=item ship_address1

=item ship_address2

(optional)

=item ship_city

=item ship_county

(optional, see L<FS::cust_main_county>)

=item ship_state

(see L<FS::cust_main_county>)

=item ship_zip

=item ship_country

(see L<FS::cust_main_county>)

=item ship_daytime

phone (optional)

=item ship_night

phone (optional)

=item ship_fax

phone (optional)

=item payby

Payment Type (See L<FS::payinfo_Mixin> for valid payby values)

=item payinfo

Payment Information (See L<FS::payinfo_Mixin> for data format)

=item paymask

Masked payinfo (See L<FS::payinfo_Mixin> for how this works)

=item paycvv

Card Verification Value, "CVV2" (also known as CVC2 or CID), the 3 or 4 digit number on the back (or front, for American Express) of the credit card

=item paydate

Expiration date, mm/yyyy, m/yyyy, mm/yy or m/yy

=item paystart_month

Start date month (maestro/solo cards only)

=item paystart_year

Start date year (maestro/solo cards only)

=item payissue

Issue number (maestro/solo cards only)

=item payname

Name on card or billing name

=item payip

IP address from which payment information was received

=item tax

Tax exempt, empty or `Y'

=item usernum

Order taker (see L<FS::access_user>)

=item comments

Comments (optional)

=item referral_custnum

Referring customer number

=item spool_cdr

Enable individual CDR spooling, empty or `Y'

=item dundate

A suggestion to events (see L<FS::part_bill_event">) to delay until this unix timestamp

=item squelch_cdr

Discourage individual CDR printing, empty or `Y'

=back

=head1 METHODS

=over 4

=item new HASHREF

Creates a new customer.  To add the customer to the database, see L<"insert">.

Note that this stores the hash reference, not a distinct copy of the hash it
points to.  You can ask the object for a copy with the I<hash> method.

=cut

sub table { 'cust_main'; }

=item insert [ CUST_PKG_HASHREF [ , INVOICING_LIST_ARYREF ] [ , OPTION => VALUE ... ] ]

Adds this customer to the database.  If there is an error, returns the error,
otherwise returns false.

CUST_PKG_HASHREF: If you pass a Tie::RefHash data structure to the insert
method containing FS::cust_pkg and FS::svc_I<tablename> objects, all records
are inserted atomicly, or the transaction is rolled back.  Passing an empty
hash reference is equivalent to not supplying this parameter.  There should be
a better explanation of this, but until then, here's an example:

  use Tie::RefHash;
  tie %hash, 'Tie::RefHash'; #this part is important
  %hash = (
    $cust_pkg => [ $svc_acct ],
    ...
  );
  $cust_main->insert( \%hash );

INVOICING_LIST_ARYREF: If you pass an arrarref to the insert method, it will
be set as the invoicing list (see L<"invoicing_list">).  Errors return as
expected and rollback the entire transaction; it is not necessary to call 
check_invoicing_list first.  The invoicing_list is set after the records in the
CUST_PKG_HASHREF above are inserted, so it is now possible to set an
invoicing_list destination to the newly-created svc_acct.  Here's an example:

  $cust_main->insert( {}, [ $email, 'POST' ] );

Currently available options are: I<depend_jobnum>, I<noexport> and I<tax_exemption>.

If I<depend_jobnum> is set, all provisioning jobs will have a dependancy
on the supplied jobnum (they will not run until the specific job completes).
This can be used to defer provisioning until some action completes (such
as running the customer's credit card successfully).

The I<noexport> option is deprecated.  If I<noexport> is set true, no
provisioning jobs (exports) are scheduled.  (You can schedule them later with
the B<reexport> method.)

The I<tax_exemption> option can be set to an arrayref of tax names.
FS::cust_main_exemption records will be created and inserted.

=cut

sub insert {
  my $self = shift;
  my $cust_pkgs = @_ ? shift : {};
  my $invoicing_list = @_ ? shift : '';
  my %options = @_;
  warn "$me insert called with options ".
       join(', ', map { "$_: $options{$_}" } keys %options ). "\n"
    if $DEBUG;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  my $prepay_identifier = '';
  my( $amount, $seconds, $upbytes, $downbytes, $totalbytes ) = (0, 0, 0, 0, 0);
  my $payby = '';
  if ( $self->payby eq 'PREPAY' ) {

    $self->payby('BILL');
    $prepay_identifier = $self->payinfo;
    $self->payinfo('');

    warn "  looking up prepaid card $prepay_identifier\n"
      if $DEBUG > 1;

    my $error = $self->get_prepay( $prepay_identifier,
                                   'amount_ref'     => \$amount,
                                   'seconds_ref'    => \$seconds,
                                   'upbytes_ref'    => \$upbytes,
                                   'downbytes_ref'  => \$downbytes,
                                   'totalbytes_ref' => \$totalbytes,
                                 );
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      #return "error applying prepaid card (transaction rolled back): $error";
      return $error;
    }

    $payby = 'PREP' if $amount;

  } elsif ( $self->payby =~ /^(CASH|WEST|MCRD)$/ ) {

    $payby = $1;
    $self->payby('BILL');
    $amount = $self->paid;

  }

  warn "  inserting $self\n"
    if $DEBUG > 1;

  $self->signupdate(time) unless $self->signupdate;

  $self->auto_agent_custid()
    if $conf->config('cust_main-auto_agent_custid') && ! $self->agent_custid;

  my $error = $self->SUPER::insert;
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    #return "inserting cust_main record (transaction rolled back): $error";
    return $error;
  }

  warn "  setting invoicing list\n"
    if $DEBUG > 1;

  if ( $invoicing_list ) {
    $error = $self->check_invoicing_list( $invoicing_list );
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      #return "checking invoicing_list (transaction rolled back): $error";
      return $error;
    }
    $self->invoicing_list( $invoicing_list );
  }

  warn "  setting customer tags\n"
    if $DEBUG > 1;

  foreach my $tagnum ( @{ $self->tagnum || [] } ) {
    my $cust_tag = new FS::cust_tag { 'tagnum'  => $tagnum,
                                      'custnum' => $self->custnum };
    my $error = $cust_tag->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
  }

  if ( $invoicing_list ) {
    $error = $self->check_invoicing_list( $invoicing_list );
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      #return "checking invoicing_list (transaction rolled back): $error";
      return $error;
    }
    $self->invoicing_list( $invoicing_list );
  }


  warn "  setting cust_main_exemption\n"
    if $DEBUG > 1;

  my $tax_exemption = delete $options{'tax_exemption'};
  if ( $tax_exemption ) {
    foreach my $taxname ( @$tax_exemption ) {
      my $cust_main_exemption = new FS::cust_main_exemption {
        'custnum' => $self->custnum,
        'taxname' => $taxname,
      };
      my $error = $cust_main_exemption->insert;
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return "inserting cust_main_exemption (transaction rolled back): $error";
      }
    }
  }

  if (    $conf->config('cust_main-skeleton_tables')
       && $conf->config('cust_main-skeleton_custnum') ) {

    warn "  inserting skeleton records\n"
      if $DEBUG > 1;

    my $error = $self->start_copy_skel;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }

  }

  warn "  ordering packages\n"
    if $DEBUG > 1;

  $error = $self->order_pkgs( $cust_pkgs,
                              %options,
                              'seconds_ref'    => \$seconds,
                              'upbytes_ref'    => \$upbytes,
                              'downbytes_ref'  => \$downbytes,
                              'totalbytes_ref' => \$totalbytes,
                            );
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return $error;
  }

  if ( $seconds ) {
    $dbh->rollback if $oldAutoCommit;
    return "No svc_acct record to apply pre-paid time";
  }
  if ( $upbytes || $downbytes || $totalbytes ) {
    $dbh->rollback if $oldAutoCommit;
    return "No svc_acct record to apply pre-paid data";
  }

  if ( $amount ) {
    warn "  inserting initial $payby payment of $amount\n"
      if $DEBUG > 1;
    $error = $self->insert_cust_pay($payby, $amount, $prepay_identifier);
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "inserting payment (transaction rolled back): $error";
    }
  }

  unless ( $import || $skip_fuzzyfiles ) {
    warn "  queueing fuzzyfiles update\n"
      if $DEBUG > 1;
    $error = $self->queue_fuzzyfiles_update;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "updating fuzzy search cache: $error";
    }
  }

  # cust_main exports!
  warn "  exporting\n" if $DEBUG > 1;

  my $export_args = $options{'export_args'} || [];

  my @part_export =
    map qsearch( 'part_export', {exportnum=>$_} ),
      $conf->config('cust_main-exports'); #, $agentnum

  foreach my $part_export ( @part_export ) {
    my $error = $part_export->export_insert($self, @$export_args);
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "exporting to ". $part_export->exporttype.
             " (transaction rolled back): $error";
    }
  }

  #foreach my $depend_jobnum ( @$depend_jobnums ) {
  #    warn "[$me] inserting dependancies on supplied job $depend_jobnum\n"
  #      if $DEBUG;
  #    foreach my $jobnum ( @jobnums ) {
  #      my $queue = qsearchs('queue', { 'jobnum' => $jobnum } );
  #      warn "[$me] inserting dependancy for job $jobnum on $depend_jobnum\n"
  #        if $DEBUG;
  #      my $error = $queue->depend_insert($depend_jobnum);
  #      if ( $error ) {
  #        $dbh->rollback if $oldAutoCommit;
  #        return "error queuing job dependancy: $error";
  #      }
  #    }
  #  }
  #
  #}
  #
  #if ( exists $options{'jobnums'} ) {
  #  push @{ $options{'jobnums'} }, @jobnums;
  #}

  warn "  insert complete; committing transaction\n"
    if $DEBUG > 1;

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';

}

use File::CounterFile;
sub auto_agent_custid {
  my $self = shift;

  my $format = $conf->config('cust_main-auto_agent_custid');
  my $agent_custid;
  if ( $format eq '1YMMXXXXXXXX' ) {

    my $counter = new File::CounterFile 'cust_main.agent_custid';
    $counter->lock;

    my $ym = 100000000000 + time2str('%y%m00000000', time);
    if ( $ym > $counter->value ) {
      $counter->{'value'} = $agent_custid = $ym;
      $counter->{'updated'} = 1;
    } else {
      $agent_custid = $counter->inc;
    }

    $counter->unlock;

  } else {
    die "Unknown cust_main-auto_agent_custid format: $format";
  }

  $self->agent_custid($agent_custid);

}

sub start_copy_skel {
  my $self = shift;

  #'mg_user_preference' => {},
  #'mg_user_indicator_profile.user_indicator_profile_id' => { 'mg_profile_indicator.profile_indicator_id' => { 'mg_profile_details.profile_detail_id' }, },
  #'mg_watchlist_header.watchlist_header_id' => { 'mg_watchlist_details.watchlist_details_id' },
  #'mg_user_grid_header.grid_header_id' => { 'mg_user_grid_details.user_grid_details_id' },
  #'mg_portfolio_header.portfolio_header_id' => { 'mg_portfolio_trades.portfolio_trades_id' => { 'mg_portfolio_trades_positions.portfolio_trades_positions_id' } },
  my @tables = eval(join('\n',$conf->config('cust_main-skeleton_tables')));
  die $@ if $@;

  _copy_skel( 'cust_main',                                 #tablename
              $conf->config('cust_main-skeleton_custnum'), #sourceid
              $self->custnum,                              #destid
              @tables,                                     #child tables
            );
}

#recursive subroutine, not a method
sub _copy_skel {
  my( $table, $sourceid, $destid, %child_tables ) = @_;

  my $primary_key;
  if ( $table =~ /^(\w+)\.(\w+)$/ ) {
    ( $table, $primary_key ) = ( $1, $2 );
  } else {
    my $dbdef_table = dbdef->table($table);
    $primary_key = $dbdef_table->primary_key
      or return "$table has no primary key".
                " (or do you need to run dbdef-create?)";
  }

  warn "  _copy_skel: $table.$primary_key $sourceid to $destid for ".
       join (', ', keys %child_tables). "\n"
    if $DEBUG > 2;

  foreach my $child_table_def ( keys %child_tables ) {

    my $child_table;
    my $child_pkey = '';
    if ( $child_table_def =~ /^(\w+)\.(\w+)$/ ) {
      ( $child_table, $child_pkey ) = ( $1, $2 );
    } else {
      $child_table = $child_table_def;

      $child_pkey = dbdef->table($child_table)->primary_key;
      #  or return "$table has no primary key".
      #            " (or do you need to run dbdef-create?)\n";
    }

    my $sequence = '';
    if ( keys %{ $child_tables{$child_table_def} } ) {

      return "$child_table has no primary key".
             " (run dbdef-create or try specifying it?)\n"
        unless $child_pkey;

      #false laziness w/Record::insert and only works on Pg
      #refactor the proper last-inserted-id stuff out of Record::insert if this
      # ever gets use for anything besides a quick kludge for one customer
      my $default = dbdef->table($child_table)->column($child_pkey)->default;
      $default =~ /^nextval\(\(?'"?([\w\.]+)"?'/i
        or return "can't parse $child_table.$child_pkey default value ".
                  " for sequence name: $default";
      $sequence = $1;

    }
  
    my @sel_columns = grep { $_ ne $primary_key }
                           dbdef->table($child_table)->columns;
    my $sel_columns = join(', ', @sel_columns );

    my @ins_columns = grep { $_ ne $child_pkey } @sel_columns;
    my $ins_columns = ' ( '. join(', ', $primary_key, @ins_columns ). ' ) ';
    my $placeholders = ' ( ?, '. join(', ', map '?', @ins_columns ). ' ) ';

    my $sel_st = "SELECT $sel_columns FROM $child_table".
                 " WHERE $primary_key = $sourceid";
    warn "    $sel_st\n"
      if $DEBUG > 2;
    my $sel_sth = dbh->prepare( $sel_st )
      or return dbh->errstr;
  
    $sel_sth->execute or return $sel_sth->errstr;

    while ( my $row = $sel_sth->fetchrow_hashref ) {

      warn "    selected row: ".
           join(', ', map { "$_=".$row->{$_} } keys %$row ). "\n"
        if $DEBUG > 2;

      my $statement =
        "INSERT INTO $child_table $ins_columns VALUES $placeholders";
      my $ins_sth =dbh->prepare($statement)
          or return dbh->errstr;
      my @param = ( $destid, map $row->{$_}, @ins_columns );
      warn "    $statement: [ ". join(', ', @param). " ]\n"
        if $DEBUG > 2;
      $ins_sth->execute( @param )
        or return $ins_sth->errstr;

      #next unless keys %{ $child_tables{$child_table} };
      next unless $sequence;
      
      #another section of that laziness
      my $seq_sql = "SELECT currval('$sequence')";
      my $seq_sth = dbh->prepare($seq_sql) or return dbh->errstr;
      $seq_sth->execute or return $seq_sth->errstr;
      my $insertid = $seq_sth->fetchrow_arrayref->[0];
  
      # don't drink soap!  recurse!  recurse!  okay!
      my $error =
        _copy_skel( $child_table_def,
                    $row->{$child_pkey}, #sourceid
                    $insertid, #destid
                    %{ $child_tables{$child_table_def} },
                  );
      return $error if $error;

    }

  }

  return '';

}

=item order_pkg HASHREF | OPTION => VALUE ... 

Orders a single package.

Options may be passed as a list of key/value pairs or as a hash reference.
Options are:

=over 4

=item cust_pkg

FS::cust_pkg object

=item cust_location

Optional FS::cust_location object

=item svcs

Optional arryaref of FS::svc_* service objects.

=item depend_jobnum

If this option is set to a job queue jobnum (see L<FS::queue>), all provisioning
jobs will have a dependancy on the supplied job (they will not run until the
specific job completes).  This can be used to defer provisioning until some
action completes (such as running the customer's credit card successfully).

=item ticket_subject

Optional subject for a ticket created and attached to this customer

=item ticket_subject

Optional queue name for ticket additions

=back

=cut

sub order_pkg {
  my $self = shift;
  my $opt = ref($_[0]) ? shift : { @_ };

  warn "$me order_pkg called with options ".
       join(', ', map { "$_: $opt->{$_}" } keys %$opt ). "\n"
    if $DEBUG;

  my $cust_pkg = $opt->{'cust_pkg'};
  my $svcs     = $opt->{'svcs'} || [];

  my %svc_options = ();
  $svc_options{'depend_jobnum'} = $opt->{'depend_jobnum'}
    if exists($opt->{'depend_jobnum'}) && $opt->{'depend_jobnum'};

  my %insert_params = map { $opt->{$_} ? ( $_ => $opt->{$_} ) : () }
                          qw( ticket_subject ticket_queue );

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  if ( $opt->{'cust_location'} &&
       ( ! $cust_pkg->locationnum || $cust_pkg->locationnum == -1 ) ) {
    my $error = $opt->{'cust_location'}->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "inserting cust_location (transaction rolled back): $error";
    }
    $cust_pkg->locationnum($opt->{'cust_location'}->locationnum);
  }

  $cust_pkg->custnum( $self->custnum );

  my $error = $cust_pkg->insert( %insert_params );
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return "inserting cust_pkg (transaction rolled back): $error";
  }

  foreach my $svc_something ( @{ $opt->{'svcs'} } ) {
    if ( $svc_something->svcnum ) {
      my $old_cust_svc = $svc_something->cust_svc;
      my $new_cust_svc = new FS::cust_svc { $old_cust_svc->hash };
      $new_cust_svc->pkgnum( $cust_pkg->pkgnum);
      $error = $new_cust_svc->replace($old_cust_svc);
    } else {
      $svc_something->pkgnum( $cust_pkg->pkgnum );
      if ( $svc_something->isa('FS::svc_acct') ) {
        foreach ( grep { $opt->{$_.'_ref'} && ${ $opt->{$_.'_ref'} } }
                       qw( seconds upbytes downbytes totalbytes )      ) {
          $svc_something->$_( $svc_something->$_() + ${ $opt->{$_.'_ref'} } );
          ${ $opt->{$_.'_ref'} } = 0;
        }
      }
      $error = $svc_something->insert(%svc_options);
    }
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "inserting svc_ (transaction rolled back): $error";
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  ''; #no error

}

#deprecated #=item order_pkgs HASHREF [ , SECONDSREF ] [ , OPTION => VALUE ... ]
=item order_pkgs HASHREF [ , OPTION => VALUE ... ]

Like the insert method on an existing record, this method orders multiple
packages and included services atomicaly.  Pass a Tie::RefHash data structure
to this method containing FS::cust_pkg and FS::svc_I<tablename> objects.
There should be a better explanation of this, but until then, here's an
example:

  use Tie::RefHash;
  tie %hash, 'Tie::RefHash'; #this part is important
  %hash = (
    $cust_pkg => [ $svc_acct ],
    ...
  );
  $cust_main->order_pkgs( \%hash, 'noexport'=>1 );

Services can be new, in which case they are inserted, or existing unaudited
services, in which case they are linked to the newly-created package.

Currently available options are: I<depend_jobnum>, I<noexport>, I<seconds_ref>,
I<upbytes_ref>, I<downbytes_ref>, and I<totalbytes_ref>.

If I<depend_jobnum> is set, all provisioning jobs will have a dependancy
on the supplied jobnum (they will not run until the specific job completes).
This can be used to defer provisioning until some action completes (such
as running the customer's credit card successfully).

The I<noexport> option is deprecated.  If I<noexport> is set true, no
provisioning jobs (exports) are scheduled.  (You can schedule them later with
the B<reexport> method for each cust_pkg object.  Using the B<reexport> method
on the cust_main object is not recommended, as existing services will also be
reexported.)

If I<seconds_ref>, I<upbytes_ref>, I<downbytes_ref>, or I<totalbytes_ref> is
provided, the scalars (provided by references) will be incremented by the
values of the prepaid card.`

=cut

sub order_pkgs {
  my $self = shift;
  my $cust_pkgs = shift;
  my $seconds_ref = ref($_[0]) ? shift : ''; #deprecated
  my %options = @_;
  $seconds_ref ||= $options{'seconds_ref'};

  warn "$me order_pkgs called with options ".
       join(', ', map { "$_: $options{$_}" } keys %options ). "\n"
    if $DEBUG;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  local $FS::svc_Common::noexport_hack = 1 if $options{'noexport'};

  foreach my $cust_pkg ( keys %$cust_pkgs ) {

    my $error = $self->order_pkg(
      'cust_pkg'     => $cust_pkg,
      'svcs'         => $cust_pkgs->{$cust_pkg},
      'seconds_ref'  => $seconds_ref,
      map { $_ => $options{$_} } qw( upbytes_ref downbytes_ref totalbytes_ref
                                     depend_jobnum
                                   )
    );
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }

  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  ''; #no error
}

=item recharge_prepay IDENTIFIER | PREPAY_CREDIT_OBJ [ , AMOUNTREF, SECONDSREF, UPBYTEREF, DOWNBYTEREF ]

Recharges this (existing) customer with the specified prepaid card (see
L<FS::prepay_credit>), specified either by I<identifier> or as an
FS::prepay_credit object.  If there is an error, returns the error, otherwise
returns false.

Optionally, five scalar references can be passed as well.  They will have their
values filled in with the amount, number of seconds, and number of upload,
download, and total bytes applied by this prepaid card.

=cut

#the ref bullshit here should be refactored like get_prepay.  MyAccount.pm is
#the only place that uses these args
sub recharge_prepay { 
  my( $self, $prepay_credit, $amountref, $secondsref, 
      $upbytesref, $downbytesref, $totalbytesref ) = @_;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  my( $amount, $seconds, $upbytes, $downbytes, $totalbytes) = ( 0, 0, 0, 0, 0 );

  my $error = $self->get_prepay( $prepay_credit,
                                 'amount_ref'     => \$amount,
                                 'seconds_ref'    => \$seconds,
                                 'upbytes_ref'    => \$upbytes,
                                 'downbytes_ref'  => \$downbytes,
                                 'totalbytes_ref' => \$totalbytes,
                               )
           || $self->increment_seconds($seconds)
           || $self->increment_upbytes($upbytes)
           || $self->increment_downbytes($downbytes)
           || $self->increment_totalbytes($totalbytes)
           || $self->insert_cust_pay_prepay( $amount,
                                             ref($prepay_credit)
                                               ? $prepay_credit->identifier
                                               : $prepay_credit
                                           );

  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return $error;
  }

  if ( defined($amountref)  ) { $$amountref  = $amount;  }
  if ( defined($secondsref) ) { $$secondsref = $seconds; }
  if ( defined($upbytesref) ) { $$upbytesref = $upbytes; }
  if ( defined($downbytesref) ) { $$downbytesref = $downbytes; }
  if ( defined($totalbytesref) ) { $$totalbytesref = $totalbytes; }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';

}

=item get_prepay IDENTIFIER | PREPAY_CREDIT_OBJ [ , OPTION => VALUE ... ]

Looks up and deletes a prepaid card (see L<FS::prepay_credit>),
specified either by I<identifier> or as an FS::prepay_credit object.

Available options are: I<amount_ref>, I<seconds_ref>, I<upbytes_ref>, I<downbytes_ref>, and I<totalbytes_ref>.  The scalars (provided by references) will be
incremented by the values of the prepaid card.

If the prepaid card specifies an I<agentnum> (see L<FS::agent>), it is used to
check or set this customer's I<agentnum>.

If there is an error, returns the error, otherwise returns false.

=cut


sub get_prepay {
  my( $self, $prepay_credit, %opt ) = @_;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  unless ( ref($prepay_credit) ) {

    my $identifier = $prepay_credit;

    $prepay_credit = qsearchs(
      'prepay_credit',
      { 'identifier' => $prepay_credit },
      '',
      'FOR UPDATE'
    );

    unless ( $prepay_credit ) {
      $dbh->rollback if $oldAutoCommit;
      return "Invalid prepaid card: ". $identifier;
    }

  }

  if ( $prepay_credit->agentnum ) {
    if ( $self->agentnum && $self->agentnum != $prepay_credit->agentnum ) {
      $dbh->rollback if $oldAutoCommit;
      return "prepaid card not valid for agent ". $self->agentnum;
    }
    $self->agentnum($prepay_credit->agentnum);
  }

  my $error = $prepay_credit->delete;
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return "removing prepay_credit (transaction rolled back): $error";
  }

  ${ $opt{$_.'_ref'} } += $prepay_credit->$_()
    for grep $opt{$_.'_ref'}, qw( amount seconds upbytes downbytes totalbytes );

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';

}

=item increment_upbytes SECONDS

Updates this customer's single or primary account (see L<FS::svc_acct>) by
the specified number of upbytes.  If there is an error, returns the error,
otherwise returns false.

=cut

sub increment_upbytes {
  _increment_column( shift, 'upbytes', @_);
}

=item increment_downbytes SECONDS

Updates this customer's single or primary account (see L<FS::svc_acct>) by
the specified number of downbytes.  If there is an error, returns the error,
otherwise returns false.

=cut

sub increment_downbytes {
  _increment_column( shift, 'downbytes', @_);
}

=item increment_totalbytes SECONDS

Updates this customer's single or primary account (see L<FS::svc_acct>) by
the specified number of totalbytes.  If there is an error, returns the error,
otherwise returns false.

=cut

sub increment_totalbytes {
  _increment_column( shift, 'totalbytes', @_);
}

=item increment_seconds SECONDS

Updates this customer's single or primary account (see L<FS::svc_acct>) by
the specified number of seconds.  If there is an error, returns the error,
otherwise returns false.

=cut

sub increment_seconds {
  _increment_column( shift, 'seconds', @_);
}

=item _increment_column AMOUNT

Updates this customer's single or primary account (see L<FS::svc_acct>) by
the specified number of seconds or bytes.  If there is an error, returns
the error, otherwise returns false.

=cut

sub _increment_column {
  my( $self, $column, $amount ) = @_;
  warn "$me increment_column called: $column, $amount\n"
    if $DEBUG;

  return '' unless $amount;

  my @cust_pkg = grep { $_->part_pkg->svcpart('svc_acct') }
                      $self->ncancelled_pkgs;

  if ( ! @cust_pkg ) {
    return 'No packages with primary or single services found'.
           ' to apply pre-paid time';
  } elsif ( scalar(@cust_pkg) > 1 ) {
    #maybe have a way to specify the package/account?
    return 'Multiple packages found to apply pre-paid time';
  }

  my $cust_pkg = $cust_pkg[0];
  warn "  found package pkgnum ". $cust_pkg->pkgnum. "\n"
    if $DEBUG > 1;

  my @cust_svc =
    $cust_pkg->cust_svc( $cust_pkg->part_pkg->svcpart('svc_acct') );

  if ( ! @cust_svc ) {
    return 'No account found to apply pre-paid time';
  } elsif ( scalar(@cust_svc) > 1 ) {
    return 'Multiple accounts found to apply pre-paid time';
  }
  
  my $svc_acct = $cust_svc[0]->svc_x;
  warn "  found service svcnum ". $svc_acct->pkgnum.
       ' ('. $svc_acct->email. ")\n"
    if $DEBUG > 1;

  $column = "increment_$column";
  $svc_acct->$column($amount);

}

=item insert_cust_pay_prepay AMOUNT [ PAYINFO ]

Inserts a prepayment in the specified amount for this customer.  An optional
second argument can specify the prepayment identifier for tracking purposes.
If there is an error, returns the error, otherwise returns false.

=cut

sub insert_cust_pay_prepay {
  shift->insert_cust_pay('PREP', @_);
}

=item insert_cust_pay_cash AMOUNT [ PAYINFO ]

Inserts a cash payment in the specified amount for this customer.  An optional
second argument can specify the payment identifier for tracking purposes.
If there is an error, returns the error, otherwise returns false.

=cut

sub insert_cust_pay_cash {
  shift->insert_cust_pay('CASH', @_);
}

=item insert_cust_pay_west AMOUNT [ PAYINFO ]

Inserts a Western Union payment in the specified amount for this customer.  An
optional second argument can specify the prepayment identifier for tracking
purposes.  If there is an error, returns the error, otherwise returns false.

=cut

sub insert_cust_pay_west {
  shift->insert_cust_pay('WEST', @_);
}

sub insert_cust_pay {
  my( $self, $payby, $amount ) = splice(@_, 0, 3);
  my $payinfo = scalar(@_) ? shift : '';

  my $cust_pay = new FS::cust_pay {
    'custnum' => $self->custnum,
    'paid'    => sprintf('%.2f', $amount),
    #'_date'   => #date the prepaid card was purchased???
    'payby'   => $payby,
    'payinfo' => $payinfo,
  };
  $cust_pay->insert;

}

=item reexport

This method is deprecated.  See the I<depend_jobnum> option to the insert and
order_pkgs methods for a better way to defer provisioning.

Re-schedules all exports by calling the B<reexport> method of all associated
packages (see L<FS::cust_pkg>).  If there is an error, returns the error;
otherwise returns false.

=cut

sub reexport {
  my $self = shift;

  carp "WARNING: FS::cust_main::reexport is deprectated; ".
       "use the depend_jobnum option to insert or order_pkgs to delay export";

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  foreach my $cust_pkg ( $self->ncancelled_pkgs ) {
    my $error = $cust_pkg->reexport;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';

}

=item delete [ OPTION => VALUE ... ]

This deletes the customer.  If there is an error, returns the error, otherwise
returns false.

This will completely remove all traces of the customer record.  This is not
what you want when a customer cancels service; for that, cancel all of the
customer's packages (see L</cancel>).

If the customer has any uncancelled packages, you need to pass a new (valid)
customer number for those packages to be transferred to, as the "new_customer"
option.  Cancelled packages will be deleted.  Did I mention that this is NOT
what you want when a customer cancels service and that you really should be
looking at L<FS::cust_pkg/cancel>?  

You can't delete a customer with invoices (see L<FS::cust_bill>),
statements (see L<FS::cust_statement>), credits (see L<FS::cust_credit>),
payments (see L<FS::cust_pay>) or refunds (see L<FS::cust_refund>), unless you
set the "delete_financials" option to a true value.

=cut

sub delete {
  my( $self, %opt ) = @_;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  if ( qsearch('agent', { 'agent_custnum' => $self->custnum } ) ) {
     $dbh->rollback if $oldAutoCommit;
     return "Can't delete a master agent customer";
  }

  #use FS::access_user
  if ( qsearch('access_user', { 'user_custnum' => $self->custnum } ) ) {
     $dbh->rollback if $oldAutoCommit;
     return "Can't delete a master employee customer";
  }

  tie my %financial_tables, 'Tie::IxHash',
    'cust_bill'      => 'invoices',
    'cust_statement' => 'statements',
    'cust_credit'    => 'credits',
    'cust_pay'       => 'payments',
    'cust_refund'    => 'refunds',
  ;
   
  foreach my $table ( keys %financial_tables ) {

    my @records = $self->$table();

    if ( @records && ! $opt{'delete_financials'} ) {
      $dbh->rollback if $oldAutoCommit;
      return "Can't delete a customer with ". $financial_tables{$table};
    }

    foreach my $record ( @records ) {
      my $error = $record->delete;
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return "Error deleting ". $financial_tables{$table}. ": $error\n";
      }
    }

  }

  my @cust_pkg = $self->ncancelled_pkgs;
  if ( @cust_pkg ) {
    my $new_custnum = $opt{'new_custnum'};
    unless ( qsearchs( 'cust_main', { 'custnum' => $new_custnum } ) ) {
      $dbh->rollback if $oldAutoCommit;
      return "Invalid new customer number: $new_custnum";
    }
    foreach my $cust_pkg ( @cust_pkg ) {
      my %hash = $cust_pkg->hash;
      $hash{'custnum'} = $new_custnum;
      my $new_cust_pkg = new FS::cust_pkg ( \%hash );
      my $error = $new_cust_pkg->replace($cust_pkg,
                                         options => { $cust_pkg->options },
                                        );
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return $error;
      }
    }
  }
  my @cancelled_cust_pkg = $self->all_pkgs;
  foreach my $cust_pkg ( @cancelled_cust_pkg ) {
    my $error = $cust_pkg->delete;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
  }

  #cust_tax_adjustment in financials?
  #cust_pay_pending?  ouch
  #cust_recon?
  foreach my $table (qw(
    cust_main_invoice cust_main_exemption cust_tag cust_attachment contact
    cust_location cust_main_note cust_tax_adjustment
    cust_pay_void cust_pay_batch queue cust_tax_exempt
  )) {
    foreach my $record ( qsearch( $table, { 'custnum' => $self->custnum } ) ) {
      my $error = $record->delete;
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return $error;
      }
    }
  }

  my $sth = $dbh->prepare(
    'UPDATE cust_main SET referral_custnum = NULL WHERE referral_custnum = ?'
  ) or do {
    my $errstr = $dbh->errstr;
    $dbh->rollback if $oldAutoCommit;
    return $errstr;
  };
  $sth->execute($self->custnum) or do {
    my $errstr = $sth->errstr;
    $dbh->rollback if $oldAutoCommit;
    return $errstr;
  };

  #tickets

  my $ticket_dbh = '';
  if ($conf->config('ticket_system') eq 'RT_Internal') {
    $ticket_dbh = $dbh;
  } elsif ($conf->config('ticket_system') eq 'RT_External') {
    my ($datasrc, $user, $pass) = $conf->config('ticket_system-rt_external_datasrc');
    $ticket_dbh = DBI->connect($datasrc, $user, $pass, { 'ChopBlanks' => 1 });
      #or die "RT_External DBI->connect error: $DBI::errstr\n";
  }

  if ( $ticket_dbh ) {

    my $ticket_sth = $ticket_dbh->prepare(
      'DELETE FROM Links WHERE Target = ?'
    ) or do {
      my $errstr = $ticket_dbh->errstr;
      $dbh->rollback if $oldAutoCommit;
      return $errstr;
    };
    $ticket_sth->execute('freeside://freeside/cust_main/'.$self->custnum)
      or do {
        my $errstr = $ticket_sth->errstr;
        $dbh->rollback if $oldAutoCommit;
        return $errstr;
      };

    #check and see if the customer is the only link on the ticket, and
    #if so, set the ticket to deleted status in RT?
    #maybe someday, for now this will at least fix tickets not displaying

  }

  #delete the customer record

  my $error = $self->SUPER::delete;
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return $error;
  }

  # cust_main exports!

  #my $export_args = $options{'export_args'} || [];

  my @part_export =
    map qsearch( 'part_export', {exportnum=>$_} ),
      $conf->config('cust_main-exports'); #, $agentnum

  foreach my $part_export ( @part_export ) {
    my $error = $part_export->export_delete( $self ); #, @$export_args);
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "exporting to ". $part_export->exporttype.
             " (transaction rolled back): $error";
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';

}

=item replace [ OLD_RECORD ] [ INVOICING_LIST_ARYREF ] [ , OPTION => VALUE ... ] ]


Replaces the OLD_RECORD with this one in the database.  If there is an error,
returns the error, otherwise returns false.

INVOICING_LIST_ARYREF: If you pass an arrarref to the insert method, it will
be set as the invoicing list (see L<"invoicing_list">).  Errors return as
expected and rollback the entire transaction; it is not necessary to call 
check_invoicing_list first.  Here's an example:

  $new_cust_main->replace( $old_cust_main, [ $email, 'POST' ] );

Currently available options are: I<tax_exemption>.

The I<tax_exemption> option can be set to an arrayref of tax names.
FS::cust_main_exemption records will be deleted and inserted as appropriate.

=cut

sub replace {
  my $self = shift;

  my $old = ( blessed($_[0]) && $_[0]->isa('FS::Record') )
              ? shift
              : $self->replace_old;

  my @param = @_;

  warn "$me replace called\n"
    if $DEBUG;

  my $curuser = $FS::CurrentUser::CurrentUser;
  if (    $self->payby eq 'COMP'
       && $self->payby ne $old->payby
       && ! $curuser->access_right('Complimentary customer')
     )
  {
    return "You are not permitted to create complimentary accounts.";
  }

  local($ignore_expired_card) = 1
    if $old->payby  =~ /^(CARD|DCRD)$/
    && $self->payby =~ /^(CARD|DCRD)$/
    && ( $old->payinfo eq $self->payinfo || $old->paymask eq $self->paymask );

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  my $error = $self->SUPER::replace($old);

  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return $error;
  }

  if ( @param && ref($param[0]) eq 'ARRAY' ) { # INVOICING_LIST_ARYREF
    my $invoicing_list = shift @param;
    $error = $self->check_invoicing_list( $invoicing_list );
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
    $self->invoicing_list( $invoicing_list );
  }

  if ( $self->exists('tagnum') ) { #so we don't delete these on edit by accident

    #this could be more efficient than deleting and re-inserting, if it matters
    foreach my $cust_tag (qsearch('cust_tag', {'custnum'=>$self->custnum} )) {
      my $error = $cust_tag->delete;
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return $error;
      }
    }
    foreach my $tagnum ( @{ $self->tagnum || [] } ) {
      my $cust_tag = new FS::cust_tag { 'tagnum'  => $tagnum,
                                        'custnum' => $self->custnum };
      my $error = $cust_tag->insert;
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return $error;
      }
    }

  }

  my %options = @param;

  my $tax_exemption = delete $options{'tax_exemption'};
  if ( $tax_exemption ) {

    my %cust_main_exemption =
      map { $_->taxname => $_ }
          qsearch('cust_main_exemption', { 'custnum' => $old->custnum } );

    foreach my $taxname ( @$tax_exemption ) {

      next if delete $cust_main_exemption{$taxname};

      my $cust_main_exemption = new FS::cust_main_exemption {
        'custnum' => $self->custnum,
        'taxname' => $taxname,
      };
      my $error = $cust_main_exemption->insert;
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return "inserting cust_main_exemption (transaction rolled back): $error";
      }
    }

    foreach my $cust_main_exemption ( values %cust_main_exemption ) {
      my $error = $cust_main_exemption->delete;
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return "deleting cust_main_exemption (transaction rolled back): $error";
      }
    }

  }

  if ( $self->payby =~ /^(CARD|CHEK|LECB)$/
       && ( ( $self->get('payinfo') ne $old->get('payinfo')
              && $self->get('payinfo') !~ /^99\d{14}$/ 
            )
            || grep { $self->get($_) ne $old->get($_) } qw(paydate payname)
          )
     )
  {

    # card/check/lec info has changed, want to retry realtime_ invoice events
    my $error = $self->retry_realtime;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
  }

  unless ( $import || $skip_fuzzyfiles ) {
    $error = $self->queue_fuzzyfiles_update;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "updating fuzzy search cache: $error";
    }
  }

  # cust_main exports!

  my $export_args = $options{'export_args'} || [];

  my @part_export =
    map qsearch( 'part_export', {exportnum=>$_} ),
      $conf->config('cust_main-exports'); #, $agentnum

  foreach my $part_export ( @part_export ) {
    my $error = $part_export->export_replace( $self, $old, @$export_args);
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "exporting to ". $part_export->exporttype.
             " (transaction rolled back): $error";
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';

}

=item queue_fuzzyfiles_update

Used by insert & replace to update the fuzzy search cache

=cut

sub queue_fuzzyfiles_update {
  my $self = shift;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  my $queue = new FS::queue { 'job' => 'FS::cust_main::append_fuzzyfiles' };
  my $error = $queue->insert( map $self->getfield($_), @fuzzyfields );
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return "queueing job (transaction rolled back): $error";
  }

  if ( $self->ship_last ) {
    $queue = new FS::queue { 'job' => 'FS::cust_main::append_fuzzyfiles' };
    $error = $queue->insert( map $self->getfield("ship_$_"), @fuzzyfields );
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "queueing job (transaction rolled back): $error";
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';

}

=item check

Checks all fields to make sure this is a valid customer record.  If there is
an error, returns the error, otherwise returns false.  Called by the insert
and replace methods.

=cut

sub check {
  my $self = shift;

  warn "$me check BEFORE: \n". $self->_dump
    if $DEBUG > 2;

  my $error =
    $self->ut_numbern('custnum')
    || $self->ut_number('agentnum')
    || $self->ut_textn('agent_custid')
    || $self->ut_number('refnum')
    || $self->ut_foreign_keyn('classnum', 'cust_class', 'classnum')
    || $self->ut_textn('custbatch')
    || $self->ut_name('last')
    || $self->ut_name('first')
    || $self->ut_snumbern('birthdate')
    || $self->ut_snumbern('signupdate')
    || $self->ut_textn('company')
    || $self->ut_text('address1')
    || $self->ut_textn('address2')
    || $self->ut_text('city')
    || $self->ut_textn('county')
    || $self->ut_textn('state')
    || $self->ut_country('country')
    || $self->ut_anything('comments')
    || $self->ut_numbern('referral_custnum')
    || $self->ut_textn('stateid')
    || $self->ut_textn('stateid_state')
    || $self->ut_textn('invoice_terms')
    || $self->ut_alphan('geocode')
    || $self->ut_floatn('cdr_termination_percentage')
  ;

  #barf.  need message catalogs.  i18n.  etc.
  $error .= "Please select an advertising source."
    if $error =~ /^Illegal or empty \(numeric\) refnum: /;
  return $error if $error;

  return "Unknown agent"
    unless qsearchs( 'agent', { 'agentnum' => $self->agentnum } );

  return "Unknown refnum"
    unless qsearchs( 'part_referral', { 'refnum' => $self->refnum } );

  return "Unknown referring custnum: ". $self->referral_custnum
    unless ! $self->referral_custnum 
           || qsearchs( 'cust_main', { 'custnum' => $self->referral_custnum } );

  if ( $self->censustract ne '' ) {
    $self->censustract =~ /^\s*(\d{9})\.?(\d{2})\s*$/
      or return "Illegal census tract: ". $self->censustract;
    
    $self->censustract("$1.$2");
  }

  if ( $self->ss eq '' ) {
    $self->ss('');
  } else {
    my $ss = $self->ss;
    $ss =~ s/\D//g;
    $ss =~ /^(\d{3})(\d{2})(\d{4})$/
      or return "Illegal social security number: ". $self->ss;
    $self->ss("$1-$2-$3");
  }


# bad idea to disable, causes billing to fail because of no tax rates later
# except we don't fail any more
  unless ( $import ) {
    unless ( qsearch('cust_main_county', {
      'country' => $self->country,
      'state'   => '',
     } ) ) {
      return "Unknown state/county/country: ".
        $self->state. "/". $self->county. "/". $self->country
        unless qsearch('cust_main_county',{
          'state'   => $self->state,
          'county'  => $self->county,
          'country' => $self->country,
        } );
    }
  }

  $error =
    $self->ut_phonen('daytime', $self->country)
    || $self->ut_phonen('night', $self->country)
    || $self->ut_phonen('fax', $self->country)
  ;
  return $error if $error;

  unless ( $ignore_illegal_zip ) {
    $error = $self->ut_zip('zip', $self->country);
    return $error if $error;
  }

  if ( $conf->exists('cust_main-require_phone')
       && ! length($self->daytime) && ! length($self->night)
     ) {

    my $daytime_label = FS::Msgcat::_gettext('daytime') =~ /^(daytime)?$/
                          ? 'Day Phone'
                          : FS::Msgcat::_gettext('daytime');
    my $night_label = FS::Msgcat::_gettext('night') =~ /^(night)?$/
                        ? 'Night Phone'
                        : FS::Msgcat::_gettext('night');
  
    return "$daytime_label or $night_label is required"
  
  }

  if ( $self->has_ship_address
       && scalar ( grep { $self->getfield($_) ne $self->getfield("ship_$_") }
                        $self->addr_fields )
     )
  {
    my $error =
      $self->ut_name('ship_last')
      || $self->ut_name('ship_first')
      || $self->ut_textn('ship_company')
      || $self->ut_text('ship_address1')
      || $self->ut_textn('ship_address2')
      || $self->ut_text('ship_city')
      || $self->ut_textn('ship_county')
      || $self->ut_textn('ship_state')
      || $self->ut_country('ship_country')
    ;
    return $error if $error;

    #false laziness with above
    unless ( qsearchs('cust_main_county', {
      'country' => $self->ship_country,
      'state'   => '',
     } ) ) {
      return "Unknown ship_state/ship_county/ship_country: ".
        $self->ship_state. "/". $self->ship_county. "/". $self->ship_country
        unless qsearch('cust_main_county',{
          'state'   => $self->ship_state,
          'county'  => $self->ship_county,
          'country' => $self->ship_country,
        } );
    }
    #eofalse

    $error =
      $self->ut_phonen('ship_daytime', $self->ship_country)
      || $self->ut_phonen('ship_night', $self->ship_country)
      || $self->ut_phonen('ship_fax', $self->ship_country)
    ;
    return $error if $error;

    unless ( $ignore_illegal_zip ) {
      $error = $self->ut_zip('ship_zip', $self->ship_country);
      return $error if $error;
    }
    return "Unit # is required."
      if $self->ship_address2 =~ /^\s*$/
      && $conf->exists('cust_main-require_address2');

  } else { # ship_ info eq billing info, so don't store dup info in database

    $self->setfield("ship_$_", '')
      foreach $self->addr_fields;

    return "Unit # is required."
      if $self->address2 =~ /^\s*$/
      && $conf->exists('cust_main-require_address2');

  }

  #$self->payby =~ /^(CARD|DCRD|CHEK|DCHK|LECB|BILL|COMP|PREPAY|CASH|WEST|MCRD)$/
  #  or return "Illegal payby: ". $self->payby;
  #$self->payby($1);
  FS::payby->can_payby($self->table, $self->payby)
    or return "Illegal payby: ". $self->payby;

  $error =    $self->ut_numbern('paystart_month')
           || $self->ut_numbern('paystart_year')
           || $self->ut_numbern('payissue')
           || $self->ut_textn('paytype')
  ;
  return $error if $error;

  if ( $self->payip eq '' ) {
    $self->payip('');
  } else {
    $error = $self->ut_ip('payip');
    return $error if $error;
  }

  # If it is encrypted and the private key is not availaible then we can't
  # check the credit card.
  my $check_payinfo = ! $self->is_encrypted($self->payinfo);

  if ( $check_payinfo && $self->payby =~ /^(CARD|DCRD)$/ ) {

    my $payinfo = $self->payinfo;
    $payinfo =~ s/\D//g;
    $payinfo =~ /^(\d{13,16})$/
      or return gettext('invalid_card'); # . ": ". $self->payinfo;
    $payinfo = $1;
    $self->payinfo($payinfo);
    validate($payinfo)
      or return gettext('invalid_card'); # . ": ". $self->payinfo;

    return gettext('unknown_card_type')
      if $self->payinfo !~ /^99\d{14}$/ #token
      && cardtype($self->payinfo) eq "Unknown";

    unless ( $ignore_banned_card ) {
      my $ban = qsearchs('banned_pay', $self->_banned_pay_hashref);
      if ( $ban ) {
        return 'Banned credit card: banned on '.
               time2str('%a %h %o at %r', $ban->_date).
               ' by '. $ban->otaker.
               ' (ban# '. $ban->bannum. ')';
      }
    }

    if (length($self->paycvv) && !$self->is_encrypted($self->paycvv)) {
      if ( cardtype($self->payinfo) eq 'American Express card' ) {
        $self->paycvv =~ /^(\d{4})$/
          or return "CVV2 (CID) for American Express cards is four digits.";
        $self->paycvv($1);
      } else {
        $self->paycvv =~ /^(\d{3})$/
          or return "CVV2 (CVC2/CID) is three digits.";
        $self->paycvv($1);
      }
    } else {
      $self->paycvv('');
    }

    my $cardtype = cardtype($payinfo);
    if ( $cardtype =~ /^(Switch|Solo)$/i ) {

      return "Start date or issue number is required for $cardtype cards"
        unless $self->paystart_month && $self->paystart_year or $self->payissue;

      return "Start month must be between 1 and 12"
        if $self->paystart_month
           and $self->paystart_month < 1 || $self->paystart_month > 12;

      return "Start year must be 1990 or later"
        if $self->paystart_year
           and $self->paystart_year < 1990;

      return "Issue number must be beween 1 and 99"
        if $self->payissue
          and $self->payissue < 1 || $self->payissue > 99;

    } else {
      $self->paystart_month('');
      $self->paystart_year('');
      $self->payissue('');
    }

  } elsif ( $check_payinfo && $self->payby =~ /^(CHEK|DCHK)$/ ) {

    my $payinfo = $self->payinfo;
    $payinfo =~ s/[^\d\@]//g;
    if ( $conf->exists('echeck-nonus') ) {
      $payinfo =~ /^(\d+)\@(\d+)$/ or return 'invalid echeck account@aba';
      $payinfo = "$1\@$2";
    } else {
      $payinfo =~ /^(\d+)\@(\d{9})$/ or return 'invalid echeck account@aba';
      $payinfo = "$1\@$2";
    }
    $self->payinfo($payinfo);
    $self->paycvv('');

    my $ban = qsearchs('banned_pay', $self->_banned_pay_hashref);
    if ( $ban ) {
      return 'Banned ACH account: banned on '.
             time2str('%a %h %o at %r', $ban->_date).
             ' by '. $ban->otaker.
             ' (ban# '. $ban->bannum. ')';
    }

  } elsif ( $self->payby eq 'LECB' ) {

    my $payinfo = $self->payinfo;
    $payinfo =~ s/\D//g;
    $payinfo =~ /^1?(\d{10})$/ or return 'invalid btn billing telephone number';
    $payinfo = $1;
    $self->payinfo($payinfo);
    $self->paycvv('');

  } elsif ( $self->payby eq 'BILL' ) {

    $error = $self->ut_textn('payinfo');
    return "Illegal P.O. number: ". $self->payinfo if $error;
    $self->paycvv('');

  } elsif ( $self->payby eq 'COMP' ) {

    my $curuser = $FS::CurrentUser::CurrentUser;
    if (    ! $self->custnum
         && ! $curuser->access_right('Complimentary customer')
       )
    {
      return "You are not permitted to create complimentary accounts."
    }

    $error = $self->ut_textn('payinfo');
    return "Illegal comp account issuer: ". $self->payinfo if $error;
    $self->paycvv('');

  } elsif ( $self->payby eq 'PREPAY' ) {

    my $payinfo = $self->payinfo;
    $payinfo =~ s/\W//g; #anything else would just confuse things
    $self->payinfo($payinfo);
    $error = $self->ut_alpha('payinfo');
    return "Illegal prepayment identifier: ". $self->payinfo if $error;
    return "Unknown prepayment identifier"
      unless qsearchs('prepay_credit', { 'identifier' => $self->payinfo } );
    $self->paycvv('');

  }

  if ( $self->paydate eq '' || $self->paydate eq '-' ) {
    return "Expiration date required"
      unless $self->payby =~ /^(BILL|PREPAY|CHEK|DCHK|LECB|CASH|WEST|MCRD)$/;
    $self->paydate('');
  } else {
    my( $m, $y );
    if ( $self->paydate =~ /^(\d{1,2})[\/\-](\d{2}(\d{2})?)$/ ) {
      ( $m, $y ) = ( $1, length($2) == 4 ? $2 : "20$2" );
    } elsif ( $self->paydate =~ /^19(\d{2})[\/\-](\d{1,2})[\/\-]\d+$/ ) {
      ( $m, $y ) = ( $2, "19$1" );
    } elsif ( $self->paydate =~ /^(20)?(\d{2})[\/\-](\d{1,2})[\/\-]\d+$/ ) {
      ( $m, $y ) = ( $3, "20$2" );
    } else {
      return "Illegal expiration date: ". $self->paydate;
    }
    $self->paydate("$y-$m-01");
    my($nowm,$nowy)=(localtime(time))[4,5]; $nowm++; $nowy+=1900;
    return gettext('expired_card')
      if !$import
      && !$ignore_expired_card 
      && ( $y<$nowy || ( $y==$nowy && $1<$nowm ) );
  }

  if ( $self->payname eq '' && $self->payby !~ /^(CHEK|DCHK)$/ &&
       ( ! $conf->exists('require_cardname')
         || $self->payby !~ /^(CARD|DCRD)$/  ) 
  ) {
    $self->payname( $self->first. " ". $self->getfield('last') );
  } else {
    $self->payname =~ /^([\w \,\.\-\'\&]+)$/
      or return gettext('illegal_name'). " payname: ". $self->payname;
    $self->payname($1);
  }

  foreach my $flag (qw( tax spool_cdr squelch_cdr archived email_csv_cdr )) {
    $self->$flag() =~ /^(Y?)$/ or return "Illegal $flag: ". $self->$flag();
    $self->$flag($1);
  }

  $self->usernum($FS::CurrentUser::CurrentUser->usernum) unless $self->usernum;

  warn "$me check AFTER: \n". $self->_dump
    if $DEBUG > 2;

  $self->SUPER::check;
}

=item addr_fields 

Returns a list of fields which have ship_ duplicates.

=cut

sub addr_fields {
  qw( last first company
      address1 address2 city county state zip country
      daytime night fax
    );
}

=item has_ship_address

Returns true if this customer record has a separate shipping address.

=cut

sub has_ship_address {
  my $self = shift;
  scalar( grep { $self->getfield("ship_$_") ne '' } $self->addr_fields );
}

=item location_hash

Returns a list of key/value pairs, with the following keys: address1, adddress2,
city, county, state, zip, country.  The shipping address is used if present.

=cut

#geocode?  dependent on tax-ship_address config, not available in cust_location
#mostly.  not yet then.

sub location_hash {
  my $self = shift;
  my $prefix = $self->has_ship_address ? 'ship_' : '';

  map { $_ => $self->get($prefix.$_) }
      qw( address1 address2 city county state zip country geocode );
      #fields that cust_location has
}

=item all_pkgs [ EXTRA_QSEARCH_PARAMS_HASHREF ]

Returns all packages (see L<FS::cust_pkg>) for this customer.

=cut

sub all_pkgs {
  my $self = shift;
  my $extra_qsearch = ref($_[0]) ? shift : {};

  return $self->num_pkgs unless wantarray || keys(%$extra_qsearch);

  my @cust_pkg = ();
  if ( $self->{'_pkgnum'} ) {
    @cust_pkg = values %{ $self->{'_pkgnum'}->cache };
  } else {
    @cust_pkg = $self->_cust_pkg($extra_qsearch);
  }

  sort sort_packages @cust_pkg;
}

=item cust_pkg

Synonym for B<all_pkgs>.

=cut

sub cust_pkg {
  shift->all_pkgs(@_);
}

=item cust_location

Returns all locations (see L<FS::cust_location>) for this customer.

=cut

sub cust_location {
  my $self = shift;
  qsearch('cust_location', { 'custnum' => $self->custnum } );
}

=item location_label [ OPTION => VALUE ... ]

Returns the label of the service location (see analog in L<FS::cust_location>) for this customer.

Options are

=over 4

=item join_string

used to separate the address elements (defaults to ', ')

=item escape_function

a callback used for escaping the text of the address elements

=back

=cut

# false laziness with FS::cust_location::line

sub location_label {
  my $self = shift;
  my %opt = @_;

  my $separator = $opt{join_string} || ', ';
  my $escape = $opt{escape_function} || sub{ shift };
  my $line = '';
  my $cydefault = FS::conf->new->config('countrydefault') || 'US';
  my $prefix = length($self->ship_last) ? 'ship_' : '';

  my $notfirst = 0;
  foreach (qw ( address1 address2 ) ) {
    my $method = "$prefix$_";
    $line .= ($notfirst ? $separator : ''). &$escape($self->$method)
      if $self->$method;
    $notfirst++;
  }
  $notfirst = 0;
  foreach (qw ( city county state zip ) ) {
    my $method = "$prefix$_";
    if ( $self->$method ) {
      $line .= ' (' if $method eq 'county';
      $line .= ($notfirst ? ' ' : $separator). &$escape($self->$method);
      $line .= ' )' if $method eq 'county';
      $notfirst++;
    }
  }
  $line .= $separator. &$escape(code2country($self->country))
    if $self->country ne $cydefault;

  $line;
}

=item ncancelled_pkgs [ EXTRA_QSEARCH_PARAMS_HASHREF ]

Returns all non-cancelled packages (see L<FS::cust_pkg>) for this customer.

=cut

sub ncancelled_pkgs {
  my $self = shift;
  my $extra_qsearch = ref($_[0]) ? shift : {};

  return $self->num_ncancelled_pkgs unless wantarray;

  my @cust_pkg = ();
  if ( $self->{'_pkgnum'} ) {

    warn "$me ncancelled_pkgs: returning cached objects"
      if $DEBUG > 1;

    @cust_pkg = grep { ! $_->getfield('cancel') }
                values %{ $self->{'_pkgnum'}->cache };

  } else {

    warn "$me ncancelled_pkgs: searching for packages with custnum ".
         $self->custnum. "\n"
      if $DEBUG > 1;

    $extra_qsearch->{'extra_sql'} .= ' AND ( cancel IS NULL OR cancel = 0 ) ';

    @cust_pkg = $self->_cust_pkg($extra_qsearch);

  }

  sort sort_packages @cust_pkg;

}

sub _cust_pkg {
  my $self = shift;
  my $extra_qsearch = ref($_[0]) ? shift : {};

  $extra_qsearch->{'select'} ||= '*';
  $extra_qsearch->{'select'} .=
   ',( SELECT COUNT(*) FROM cust_svc WHERE cust_pkg.pkgnum = cust_svc.pkgnum )
     AS _num_cust_svc';

  map {
        $_->{'_num_cust_svc'} = $_->get('_num_cust_svc');
        $_;
      }
  qsearch({
    %$extra_qsearch,
    'table'   => 'cust_pkg',
    'hashref' => { 'custnum' => $self->custnum },
  });

}

# This should be generalized to use config options to determine order.
sub sort_packages {
  
  my $locationsort = ( $a->locationnum || 0 ) <=> ( $b->locationnum || 0 );
  return $locationsort if $locationsort;

  if ( $a->get('cancel') xor $b->get('cancel') ) {
    return -1 if $b->get('cancel');
    return  1 if $a->get('cancel');
    #shouldn't get here...
    return 0;
  } else {
    my $a_num_cust_svc = $a->num_cust_svc;
    my $b_num_cust_svc = $b->num_cust_svc;
    return 0  if !$a_num_cust_svc && !$b_num_cust_svc;
    return -1 if  $a_num_cust_svc && !$b_num_cust_svc;
    return 1  if !$a_num_cust_svc &&  $b_num_cust_svc;
    my @a_cust_svc = $a->cust_svc;
    my @b_cust_svc = $b->cust_svc;
    return 0  if !scalar(@a_cust_svc) && !scalar(@b_cust_svc);
    return -1 if  scalar(@a_cust_svc) && !scalar(@b_cust_svc);
    return 1  if !scalar(@a_cust_svc) &&  scalar(@b_cust_svc);
    $a_cust_svc[0]->svc_x->label cmp $b_cust_svc[0]->svc_x->label;
  }

}

=item suspended_pkgs

Returns all suspended packages (see L<FS::cust_pkg>) for this customer.

=cut

sub suspended_pkgs {
  my $self = shift;
  grep { $_->susp } $self->ncancelled_pkgs;
}

=item unflagged_suspended_pkgs

Returns all unflagged suspended packages (see L<FS::cust_pkg>) for this
customer (thouse packages without the `manual_flag' set).

=cut

sub unflagged_suspended_pkgs {
  my $self = shift;
  return $self->suspended_pkgs
    unless dbdef->table('cust_pkg')->column('manual_flag');
  grep { ! $_->manual_flag } $self->suspended_pkgs;
}

=item unsuspended_pkgs

Returns all unsuspended (and uncancelled) packages (see L<FS::cust_pkg>) for
this customer.

=cut

sub unsuspended_pkgs {
  my $self = shift;
  grep { ! $_->susp } $self->ncancelled_pkgs;
}

=item next_bill_date

Returns the next date this customer will be billed, as a UNIX timestamp, or
undef if no active package has a next bill date.

=cut

sub next_bill_date {
  my $self = shift;
  min( map $_->get('bill'), grep $_->get('bill'), $self->unsuspended_pkgs );
}

=item num_cancelled_pkgs

Returns the number of cancelled packages (see L<FS::cust_pkg>) for this
customer.

=cut

sub num_cancelled_pkgs {
  shift->num_pkgs("cust_pkg.cancel IS NOT NULL AND cust_pkg.cancel != 0");
}

sub num_ncancelled_pkgs {
  shift->num_pkgs("( cust_pkg.cancel IS NULL OR cust_pkg.cancel = 0 )");
}

sub num_pkgs {
  my( $self ) = shift;
  my $sql = scalar(@_) ? shift : '';
  $sql = "AND $sql" if $sql && $sql !~ /^\s*$/ && $sql !~ /^\s*AND/i;
  my $sth = dbh->prepare(
    "SELECT COUNT(*) FROM cust_pkg WHERE custnum = ? $sql"
  ) or die dbh->errstr;
  $sth->execute($self->custnum) or die $sth->errstr;
  $sth->fetchrow_arrayref->[0];
}

=item unsuspend

Unsuspends all unflagged suspended packages (see L</unflagged_suspended_pkgs>
and L<FS::cust_pkg>) for this customer.  Always returns a list: an empty list
on success or a list of errors.

=cut

sub unsuspend {
  my $self = shift;
  grep { $_->unsuspend } $self->suspended_pkgs;
}

=item suspend

Suspends all unsuspended packages (see L<FS::cust_pkg>) for this customer.

Returns a list: an empty list on success or a list of errors.

=cut

sub suspend {
  my $self = shift;
  grep { $_->suspend(@_) } $self->unsuspended_pkgs;
}

=item suspend_if_pkgpart HASHREF | PKGPART [ , PKGPART ... ]

Suspends all unsuspended packages (see L<FS::cust_pkg>) matching the listed
PKGPARTs (see L<FS::part_pkg>).  Preferred usage is to pass a hashref instead
of a list of pkgparts; the hashref has the following keys:

=over 4

=item pkgparts - listref of pkgparts

=item (other options are passed to the suspend method)

=back


Returns a list: an empty list on success or a list of errors.

=cut

sub suspend_if_pkgpart {
  my $self = shift;
  my (@pkgparts, %opt);
  if (ref($_[0]) eq 'HASH'){
    @pkgparts = @{$_[0]{pkgparts}};
    %opt      = %{$_[0]};
  }else{
    @pkgparts = @_;
  }
  grep { $_->suspend(%opt) }
    grep { my $pkgpart = $_->pkgpart; grep { $pkgpart eq $_ } @pkgparts }
      $self->unsuspended_pkgs;
}

=item suspend_unless_pkgpart HASHREF | PKGPART [ , PKGPART ... ]

Suspends all unsuspended packages (see L<FS::cust_pkg>) unless they match the
given PKGPARTs (see L<FS::part_pkg>).  Preferred usage is to pass a hashref
instead of a list of pkgparts; the hashref has the following keys:

=over 4

=item pkgparts - listref of pkgparts

=item (other options are passed to the suspend method)

=back

Returns a list: an empty list on success or a list of errors.

=cut

sub suspend_unless_pkgpart {
  my $self = shift;
  my (@pkgparts, %opt);
  if (ref($_[0]) eq 'HASH'){
    @pkgparts = @{$_[0]{pkgparts}};
    %opt      = %{$_[0]};
  }else{
    @pkgparts = @_;
  }
  grep { $_->suspend(%opt) }
    grep { my $pkgpart = $_->pkgpart; ! grep { $pkgpart eq $_ } @pkgparts }
      $self->unsuspended_pkgs;
}

=item cancel [ OPTION => VALUE ... ]

Cancels all uncancelled packages (see L<FS::cust_pkg>) for this customer.

Available options are:

=over 4

=item quiet - can be set true to supress email cancellation notices.

=item reason - can be set to a cancellation reason (see L<FS:reason>), either a reasonnum of an existing reason, or passing a hashref will create a new reason.  The hashref should have the following keys: typenum - Reason type (see L<FS::reason_type>, reason - Text of the new reason.

=item ban - can be set true to ban this customer's credit card or ACH information, if present.

=item nobill - can be set true to skip billing if it might otherwise be done.

=back

Always returns a list: an empty list on success or a list of errors.

=cut

# nb that dates are not specified as valid options to this method

sub cancel {
  my( $self, %opt ) = @_;

  warn "$me cancel called on customer ". $self->custnum. " with options ".
       join(', ', map { "$_: $opt{$_}" } keys %opt ). "\n"
    if $DEBUG;

  return ( 'access denied' )
    unless $FS::CurrentUser::CurrentUser->access_right('Cancel customer');

  if ( $opt{'ban'} && $self->payby =~ /^(CARD|DCRD|CHEK|DCHK)$/ ) {

    #should try decryption (we might have the private key)
    # and if not maybe queue a job for the server that does?
    return ( "Can't (yet) ban encrypted credit cards" )
      if $self->is_encrypted($self->payinfo);

    my $ban = new FS::banned_pay $self->_banned_pay_hashref;
    my $error = $ban->insert;
    return ( $error ) if $error;

  }

  my @pkgs = $self->ncancelled_pkgs;

  if ( !$opt{nobill} && $conf->exists('bill_usage_on_cancel') ) {
    $opt{nobill} = 1;
    my $error = $self->bill( pkg_list => [ @pkgs ], cancel => 1 );
    warn "Error billing during cancel, custnum ". $self->custnum. ": $error"
      if $error;
  }

  warn "$me cancelling ". scalar($self->ncancelled_pkgs). "/".
       scalar(@pkgs). " packages for customer ". $self->custnum. "\n"
    if $DEBUG;

  grep { $_ } map { $_->cancel(%opt) } $self->ncancelled_pkgs;
}

sub _banned_pay_hashref {
  my $self = shift;

  my %payby2ban = (
    'CARD' => 'CARD',
    'DCRD' => 'CARD',
    'CHEK' => 'CHEK',
    'DCHK' => 'CHEK'
  );

  {
    'payby'   => $payby2ban{$self->payby},
    'payinfo' => md5_base64($self->payinfo),
    #don't ever *search* on reason! #'reason'  =>
  };
}

=item notes

Returns all notes (see L<FS::cust_main_note>) for this customer.

=cut

sub notes {
  my $self = shift;
  #order by?
  qsearch( 'cust_main_note',
           { 'custnum' => $self->custnum },
	   '',
	   'ORDER BY _DATE DESC'
	 );
}

=item agent

Returns the agent (see L<FS::agent>) for this customer.

=cut

sub agent {
  my $self = shift;
  qsearchs( 'agent', { 'agentnum' => $self->agentnum } );
}

=item agent_name

Returns the agent name (see L<FS::agent>) for this customer.

=cut

sub agent_name {
  my $self = shift;
  $self->agent->agent;
}

=item cust_tag

Returns any tags associated with this customer, as FS::cust_tag objects,
or an empty list if there are no tags.

=cut

sub cust_tag {
  my $self = shift;
  qsearch('cust_tag', { 'custnum' => $self->custnum } );
}

=item part_tag

Returns any tags associated with this customer, as FS::part_tag objects,
or an empty list if there are no tags.

=cut

sub part_tag {
  my $self = shift;
  map $_->part_tag, $self->cust_tag; 
}


=item cust_class

Returns the customer class, as an FS::cust_class object, or the empty string
if there is no customer class.

=cut

sub cust_class {
  my $self = shift;
  if ( $self->classnum ) {
    qsearchs('cust_class', { 'classnum' => $self->classnum } );
  } else {
    return '';
  } 
}

=item categoryname 

Returns the customer category name, or the empty string if there is no customer
category.

=cut

sub categoryname {
  my $self = shift;
  my $cust_class = $self->cust_class;
  $cust_class
    ? $cust_class->categoryname
    : '';
}

=item classname 

Returns the customer class name, or the empty string if there is no customer
class.

=cut

sub classname {
  my $self = shift;
  my $cust_class = $self->cust_class;
  $cust_class
    ? $cust_class->classname
    : '';
}

=item BILLING METHODS

Documentation on billing methods has been moved to
L<FS::cust_main::Billing>.

=item do_cust_event [ HASHREF | OPTION => VALUE ... ]

Runs billing events; see L<FS::part_event> and the billing events web
interface.

If there is an error, returns the error, otherwise returns false.

Options are passed as name-value pairs.

Currently available options are:

=over 4

=item time

Use this time when deciding when to print invoices and late notices on those invoices.  The default is now.  It is specified as a UNIX timestamp; see L<perlfunc/"time">).  Also see L<Time::Local> and L<Date::Parse> for conversion functions.

=item check_freq

"1d" for the traditional, daily events (the default), or "1m" for the new monthly events (part_event.check_freq)

=item stage

"collect" (the default) or "pre-bill"

=item quiet
 
set true to surpress email card/ACH decline notices.

=item debug

Debugging level.  Default is 0 (no debugging), or can be set to 1 (passed-in options), 2 (traces progress), 3 (more information), or 4 (include full search queries)

=cut

# =item payby
#
# allows for one time override of normal customer billing method

# =item retry
#
# Retry card/echeck/LEC transactions even when not scheduled by invoice events.

sub do_cust_event {
  my( $self, %options ) = @_;
  my $time = $options{'time'} || time;

  #put below somehow?
  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  $self->select_for_update; #mutex

  if ( $DEBUG ) {
    my $balance = $self->balance;
    warn "$me do_cust_event customer ". $self->custnum. ": balance $balance\n"
  }

#  if ( exists($options{'retry_card'}) ) {
#    carp 'retry_card option passed to collect is deprecated; use retry';
#    $options{'retry'} ||= $options{'retry_card'};
#  }
#  if ( exists($options{'retry'}) && $options{'retry'} ) {
#    my $error = $self->retry_realtime;
#    if ( $error ) {
#      $dbh->rollback if $oldAutoCommit;
#      return $error;
#    }
#  }

  # false laziness w/pay_batch::import_results

  my $due_cust_event = $self->due_cust_event(
    'debug'      => ( $options{'debug'} || 0 ),
    'time'       => $time,
    'check_freq' => $options{'check_freq'},
    'stage'      => ( $options{'stage'} || 'collect' ),
  );
  unless( ref($due_cust_event) ) {
    $dbh->rollback if $oldAutoCommit;
    return $due_cust_event;
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  #never want to roll back an event just because it or a different one
  # returned an error
  local $FS::UID::AutoCommit = 1; #$oldAutoCommit;

  foreach my $cust_event ( @$due_cust_event ) {

    #XXX lock event
    
    #re-eval event conditions (a previous event could have changed things)
    unless ( $cust_event->test_conditions( 'time' => $time ) ) {
      #don't leave stray "new/locked" records around
      my $error = $cust_event->delete;
      return $error if $error;
      next;
    }

    {
      local $realtime_bop_decline_quiet = 1 if $options{'quiet'};
      warn "  running cust_event ". $cust_event->eventnum. "\n"
        if $DEBUG > 1;

      #if ( my $error = $cust_event->do_event(%options) ) { #XXX %options?
      if ( my $error = $cust_event->do_event() ) {
        #XXX wtf is this?  figure out a proper dealio with return value
        #from do_event
        return $error;
      }
    }

  }

  '';

}

=item due_cust_event [ HASHREF | OPTION => VALUE ... ]

Inserts database records for and returns an ordered listref of new events due
for this customer, as FS::cust_event objects (see L<FS::cust_event>).  If no
events are due, an empty listref is returned.  If there is an error, returns a
scalar error message.

To actually run the events, call each event's test_condition method, and if
still true, call the event's do_event method.

Options are passed as a hashref or as a list of name-value pairs.  Available
options are:

=over 4

=item check_freq

Search only for events of this check frequency (how often events of this type are checked); currently "1d" (daily, the default) and "1m" (monthly) are recognized.

=item stage

"collect" (the default) or "pre-bill"

=item time

"Current time" for the events.

=item debug

Debugging level.  Default is 0 (no debugging), or can be set to 1 (passed-in options), 2 (traces progress), 3 (more information), or 4 (include full search queries)

=item eventtable

Only return events for the specified eventtable (by default, events of all eventtables are returned)

=item objects

Explicitly pass the objects to be tested (typically used with eventtable).

=item testonly

Set to true to return the objects, but not actually insert them into the
database.

=back

=cut

sub due_cust_event {
  my $self = shift;
  my %opt = ref($_[0]) ? %{ $_[0] } : @_;

  #???
  #my $DEBUG = $opt{'debug'}
  local($DEBUG) = $opt{'debug'}
    if defined($opt{'debug'}) && $opt{'debug'} > $DEBUG;

  warn "$me due_cust_event called with options ".
       join(', ', map { "$_: $opt{$_}" } keys %opt). "\n"
    if $DEBUG;

  $opt{'time'} ||= time;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  $self->select_for_update #mutex
    unless $opt{testonly};

  ###
  # find possible events (initial search)
  ###
  
  my @cust_event = ();

  my @eventtable = $opt{'eventtable'}
                     ? ( $opt{'eventtable'} )
                     : FS::part_event->eventtables_runorder;

  foreach my $eventtable ( @eventtable ) {

    my @objects;
    if ( $opt{'objects'} ) {

      @objects = @{ $opt{'objects'} };

    } else {

      #my @objects = $self->eventtable(); # sub cust_main { @{ [ $self ] }; }
      @objects = ( $eventtable eq 'cust_main' )
                   ? ( $self )
                   : ( $self->$eventtable() );

    }

    my @e_cust_event = ();

    my $cross = "CROSS JOIN $eventtable";
    $cross .= ' LEFT JOIN cust_main USING ( custnum )'
      unless $eventtable eq 'cust_main';

    foreach my $object ( @objects ) {

      #this first search uses the condition_sql magic for optimization.
      #the more possible events we can eliminate in this step the better

      my $cross_where = '';
      my $pkey = $object->primary_key;
      $cross_where = "$eventtable.$pkey = ". $object->$pkey();

      my $join = FS::part_event_condition->join_conditions_sql( $eventtable );
      my $extra_sql =
        FS::part_event_condition->where_conditions_sql( $eventtable,
                                                        'time'=>$opt{'time'}
                                                      );
      my $order = FS::part_event_condition->order_conditions_sql( $eventtable );

      $extra_sql = "AND $extra_sql" if $extra_sql;

      #here is the agent virtualization
      $extra_sql .= " AND (    part_event.agentnum IS NULL
                            OR part_event.agentnum = ". $self->agentnum. ' )';

      $extra_sql .= " $order";

      warn "searching for events for $eventtable ". $object->$pkey. "\n"
        if $opt{'debug'} > 2;
      my @part_event = qsearch( {
        'debug'     => ( $opt{'debug'} > 3 ? 1 : 0 ),
        'select'    => 'part_event.*',
        'table'     => 'part_event',
        'addl_from' => "$cross $join",
        'hashref'   => { 'check_freq' => ( $opt{'check_freq'} || '1d' ),
                         'eventtable' => $eventtable,
                         'disabled'   => '',
                       },
        'extra_sql' => "AND $cross_where $extra_sql",
      } );

      if ( $DEBUG > 2 ) {
        my $pkey = $object->primary_key;
        warn "      ". scalar(@part_event).
             " possible events found for $eventtable ". $object->$pkey(). "\n";
      }

      push @e_cust_event, map { $_->new_cust_event($object) } @part_event;

    }

    warn "    ". scalar(@e_cust_event).
         " subtotal possible cust events found for $eventtable\n"
      if $DEBUG > 1;

    push @cust_event, @e_cust_event;

  }

  warn "  ". scalar(@cust_event).
       " total possible cust events found in initial search\n"
    if $DEBUG; # > 1;


  ##
  # test stage
  ##

  $opt{stage} ||= 'collect';
  @cust_event =
    grep { my $stage = $_->part_event->event_stage;
           $opt{stage} eq $stage or ( ! $stage && $opt{stage} eq 'collect' )
         }
         @cust_event;

  ##
  # test conditions
  ##
  
  my %unsat = ();

  @cust_event = grep $_->test_conditions( 'time'          => $opt{'time'},
                                          'stats_hashref' => \%unsat ),
                     @cust_event;

  warn "  ". scalar(@cust_event). " cust events left satisfying conditions\n"
    if $DEBUG; # > 1;

  warn "    invalid conditions not eliminated with condition_sql:\n".
       join('', map "      $_: ".$unsat{$_}."\n", keys %unsat )
    if keys %unsat && $DEBUG; # > 1;

  ##
  # insert
  ##

  unless( $opt{testonly} ) {
    foreach my $cust_event ( @cust_event ) {

      my $error = $cust_event->insert();
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return $error;
      }
                                       
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;

  ##
  # return
  ##

  warn "  returning events: ". Dumper(@cust_event). "\n"
    if $DEBUG > 2;

  \@cust_event;

}

=item retry_realtime

Schedules realtime / batch  credit card / electronic check / LEC billing
events for for retry.  Useful if card information has changed or manual
retry is desired.  The 'collect' method must be called to actually retry
the transaction.

Implementation details: For either this customer, or for each of this
customer's open invoices, changes the status of the first "done" (with
statustext error) realtime processing event to "failed".

=cut

sub retry_realtime {
  my $self = shift;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  #a little false laziness w/due_cust_event (not too bad, really)

  my $join = FS::part_event_condition->join_conditions_sql;
  my $order = FS::part_event_condition->order_conditions_sql;
  my $mine = 
  '( '
   . join ( ' OR ' , map { 
    "( part_event.eventtable = " . dbh->quote($_) 
    . " AND tablenum IN( SELECT " . dbdef->table($_)->primary_key . " from $_ where custnum = " . dbh->quote( $self->custnum ) . "))" ;
   } FS::part_event->eventtables)
   . ') ';

  #here is the agent virtualization
  my $agent_virt = " (    part_event.agentnum IS NULL
                       OR part_event.agentnum = ". $self->agentnum. ' )';

  #XXX this shouldn't be hardcoded, actions should declare it...
  my @realtime_events = qw(
    cust_bill_realtime_card
    cust_bill_realtime_check
    cust_bill_realtime_lec
    cust_bill_batch
  );

  my $is_realtime_event = ' ( '. join(' OR ', map "part_event.action = '$_'",
                                                  @realtime_events
                                     ).
                          ' ) ';

  my @cust_event = qsearchs({
    'table'     => 'cust_event',
    'select'    => 'cust_event.*',
    'addl_from' => "LEFT JOIN part_event USING ( eventpart ) $join",
    'hashref'   => { 'status' => 'done' },
    'extra_sql' => " AND statustext IS NOT NULL AND statustext != '' ".
                   " AND $mine AND $is_realtime_event AND $agent_virt $order" # LIMIT 1"
  });

  my %seen_invnum = ();
  foreach my $cust_event (@cust_event) {

    #max one for the customer, one for each open invoice
    my $cust_X = $cust_event->cust_X;
    next if $seen_invnum{ $cust_event->part_event->eventtable eq 'cust_bill'
                          ? $cust_X->invnum
                          : 0
                        }++
         or $cust_event->part_event->eventtable eq 'cust_bill'
            && ! $cust_X->owed;

    my $error = $cust_event->retry;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return "error scheduling event for retry: $error";
    }

  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';

}


=cut

=item REALTIME BILLING METHODS

Documentation on realtime billing methods has been moved to
L<FS::cust_main::Billing_Realtime>.

=item remove_cvv

Removes the I<paycvv> field from the database directly.

If there is an error, returns the error, otherwise returns false.

=cut

sub remove_cvv {
  my $self = shift;
  my $sth = dbh->prepare("UPDATE cust_main SET paycvv = '' WHERE custnum = ?")
    or return dbh->errstr;
  $sth->execute($self->custnum)
    or return $sth->errstr;
  $self->paycvv('');
  '';
}

=item batch_card OPTION => VALUE...

Adds a payment for this invoice to the pending credit card batch (see
L<FS::cust_pay_batch>), or, if the B<realtime> option is set to a true value,
runs the payment using a realtime gateway.

=cut

sub batch_card {
  my ($self, %options) = @_;

  my $amount;
  if (exists($options{amount})) {
    $amount = $options{amount};
  }else{
    $amount = sprintf("%.2f", $self->balance - $self->in_transit_payments);
  }
  return '' unless $amount > 0;
  
  my $invnum = delete $options{invnum};
  my $payby = $options{invnum} || $self->payby;  #dubious

  if ($options{'realtime'}) {
    return $self->realtime_bop( FS::payby->payby2bop($self->payby),
                                $amount,
                                %options,
                              );
  }

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  #this needs to handle mysql as well as Pg, like svc_acct.pm
  #(make it into a common function if folks need to do batching with mysql)
  $dbh->do("LOCK TABLE pay_batch IN SHARE ROW EXCLUSIVE MODE")
    or return "Cannot lock pay_batch: " . $dbh->errstr;

  my %pay_batch = (
    'status' => 'O',
    'payby'  => FS::payby->payby2payment($payby),
  );

  my $pay_batch = qsearchs( 'pay_batch', \%pay_batch );

  unless ( $pay_batch ) {
    $pay_batch = new FS::pay_batch \%pay_batch;
    my $error = $pay_batch->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      die "error creating new batch: $error\n";
    }
  }

  my $old_cust_pay_batch = qsearchs('cust_pay_batch', {
      'batchnum' => $pay_batch->batchnum,
      'custnum'  => $self->custnum,
  } );

  foreach (qw( address1 address2 city state zip country payby payinfo paydate
               payname )) {
    $options{$_} = '' unless exists($options{$_});
  }

  my $cust_pay_batch = new FS::cust_pay_batch ( {
    'batchnum' => $pay_batch->batchnum,
    'invnum'   => $invnum || 0,                    # is there a better value?
                                                   # this field should be
                                                   # removed...
                                                   # cust_bill_pay_batch now
    'custnum'  => $self->custnum,
    'last'     => $self->getfield('last'),
    'first'    => $self->getfield('first'),
    'address1' => $options{address1} || $self->address1,
    'address2' => $options{address2} || $self->address2,
    'city'     => $options{city}     || $self->city,
    'state'    => $options{state}    || $self->state,
    'zip'      => $options{zip}      || $self->zip,
    'country'  => $options{country}  || $self->country,
    'payby'    => $options{payby}    || $self->payby,
    'payinfo'  => $options{payinfo}  || $self->payinfo,
    'exp'      => $options{paydate}  || $self->paydate,
    'payname'  => $options{payname}  || $self->payname,
    'amount'   => $amount,                         # consolidating
  } );
  
  $cust_pay_batch->paybatchnum($old_cust_pay_batch->paybatchnum)
    if $old_cust_pay_batch;

  my $error;
  if ($old_cust_pay_batch) {
    $error = $cust_pay_batch->replace($old_cust_pay_batch)
  } else {
    $error = $cust_pay_batch->insert;
  }

  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    die $error;
  }

  my $unapplied =   $self->total_unapplied_credits
                  + $self->total_unapplied_payments
                  + $self->in_transit_payments;
  foreach my $cust_bill ($self->open_cust_bill) {
    #$dbh->commit or die $dbh->errstr if $oldAutoCommit;
    my $cust_bill_pay_batch = new FS::cust_bill_pay_batch {
      'invnum' => $cust_bill->invnum,
      'paybatchnum' => $cust_pay_batch->paybatchnum,
      'amount' => $cust_bill->owed,
      '_date' => time,
    };
    if ($unapplied >= $cust_bill_pay_batch->amount){
      $unapplied -= $cust_bill_pay_batch->amount;
      next;
    }else{
      $cust_bill_pay_batch->amount(sprintf ( "%.2f", 
                                   $cust_bill_pay_batch->amount - $unapplied ));      $unapplied = 0;
    }
    $error = $cust_bill_pay_batch->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      die $error;
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';
}

=item total_owed

Returns the total owed for this customer on all invoices
(see L<FS::cust_bill/owed>).

=cut

sub total_owed {
  my $self = shift;
  $self->total_owed_date(2145859200); #12/31/2037
}

=item total_owed_date TIME

Returns the total owed for this customer on all invoices with date earlier than
TIME.  TIME is specified as a UNIX timestamp; see L<perlfunc/"time">).  Also
see L<Time::Local> and L<Date::Parse> for conversion functions.

=cut

sub total_owed_date {
  my $self = shift;
  my $time = shift;

  my $custnum = $self->custnum;

  my $owed_sql = FS::cust_bill->owed_sql;

  my $sql = "
    SELECT SUM($owed_sql) FROM cust_bill
      WHERE custnum = $custnum
        AND _date <= $time
  ";

  sprintf( "%.2f", $self->scalar_sql($sql) );

}

=item total_owed_pkgnum PKGNUM

Returns the total owed on all invoices for this customer's specific package
when using experimental package balances (see L<FS::cust_bill/owed_pkgnum>).

=cut

sub total_owed_pkgnum {
  my( $self, $pkgnum ) = @_;
  $self->total_owed_date_pkgnum(2145859200, $pkgnum); #12/31/2037
}

=item total_owed_date_pkgnum TIME PKGNUM

Returns the total owed for this customer's specific package when using
experimental package balances on all invoices with date earlier than
TIME.  TIME is specified as a UNIX timestamp; see L<perlfunc/"time">).  Also
see L<Time::Local> and L<Date::Parse> for conversion functions.

=cut

sub total_owed_date_pkgnum {
  my( $self, $time, $pkgnum ) = @_;

  my $total_bill = 0;
  foreach my $cust_bill (
    grep { $_->_date <= $time }
      qsearch('cust_bill', { 'custnum' => $self->custnum, } )
  ) {
    $total_bill += $cust_bill->owed_pkgnum($pkgnum);
  }
  sprintf( "%.2f", $total_bill );

}

=item total_paid

Returns the total amount of all payments.

=cut

sub total_paid {
  my $self = shift;
  my $total = 0;
  $total += $_->paid foreach $self->cust_pay;
  sprintf( "%.2f", $total );
}

=item total_unapplied_credits

Returns the total outstanding credit (see L<FS::cust_credit>) for this
customer.  See L<FS::cust_credit/credited>.

=item total_credited

Old name for total_unapplied_credits.  Don't use.

=cut

sub total_credited {
  #carp "total_credited deprecated, use total_unapplied_credits";
  shift->total_unapplied_credits(@_);
}

sub total_unapplied_credits {
  my $self = shift;

  my $custnum = $self->custnum;

  my $unapplied_sql = FS::cust_credit->unapplied_sql;

  my $sql = "
    SELECT SUM($unapplied_sql) FROM cust_credit
      WHERE custnum = $custnum
  ";

  sprintf( "%.2f", $self->scalar_sql($sql) );

}

=item total_unapplied_credits_pkgnum PKGNUM

Returns the total outstanding credit (see L<FS::cust_credit>) for this
customer.  See L<FS::cust_credit/credited>.

=cut

sub total_unapplied_credits_pkgnum {
  my( $self, $pkgnum ) = @_;
  my $total_credit = 0;
  $total_credit += $_->credited foreach $self->cust_credit_pkgnum($pkgnum);
  sprintf( "%.2f", $total_credit );
}


=item total_unapplied_payments

Returns the total unapplied payments (see L<FS::cust_pay>) for this customer.
See L<FS::cust_pay/unapplied>.

=cut

sub total_unapplied_payments {
  my $self = shift;

  my $custnum = $self->custnum;

  my $unapplied_sql = FS::cust_pay->unapplied_sql;

  my $sql = "
    SELECT SUM($unapplied_sql) FROM cust_pay
      WHERE custnum = $custnum
  ";

  sprintf( "%.2f", $self->scalar_sql($sql) );

}

=item total_unapplied_payments_pkgnum PKGNUM

Returns the total unapplied payments (see L<FS::cust_pay>) for this customer's
specific package when using experimental package balances.  See
L<FS::cust_pay/unapplied>.

=cut

sub total_unapplied_payments_pkgnum {
  my( $self, $pkgnum ) = @_;
  my $total_unapplied = 0;
  $total_unapplied += $_->unapplied foreach $self->cust_pay_pkgnum($pkgnum);
  sprintf( "%.2f", $total_unapplied );
}


=item total_unapplied_refunds

Returns the total unrefunded refunds (see L<FS::cust_refund>) for this
customer.  See L<FS::cust_refund/unapplied>.

=cut

sub total_unapplied_refunds {
  my $self = shift;
  my $custnum = $self->custnum;

  my $unapplied_sql = FS::cust_refund->unapplied_sql;

  my $sql = "
    SELECT SUM($unapplied_sql) FROM cust_refund
      WHERE custnum = $custnum
  ";

  sprintf( "%.2f", $self->scalar_sql($sql) );

}

=item balance

Returns the balance for this customer (total_owed plus total_unrefunded, minus
total_unapplied_credits minus total_unapplied_payments).

=cut

sub balance {
  my $self = shift;
  $self->balance_date_range;
}

=item balance_date TIME

Returns the balance for this customer, only considering invoices with date
earlier than TIME (total_owed_date minus total_credited minus
total_unapplied_payments).  TIME is specified as a UNIX timestamp; see
L<perlfunc/"time">).  Also see L<Time::Local> and L<Date::Parse> for conversion
functions.

=cut

sub balance_date {
  my $self = shift;
  $self->balance_date_range(shift);
}

=item balance_date_range [ START_TIME [ END_TIME [ OPTION => VALUE ... ] ] ]

Returns the balance for this customer, optionally considering invoices with
date earlier than START_TIME, and not later than END_TIME
(total_owed_date minus total_unapplied_credits minus total_unapplied_payments).

Times are specified as SQL fragments or numeric
UNIX timestamps; see L<perlfunc/"time">).  Also see L<Time::Local> and
L<Date::Parse> for conversion functions.  The empty string can be passed
to disable that time constraint completely.

Available options are:

=over 4

=item unapplied_date

set to true to disregard unapplied credits, payments and refunds outside the specified time period - by default the time period restriction only applies to invoices (useful for reporting, probably a bad idea for event triggering)

=back

=cut

sub balance_date_range {
  my $self = shift;
  my $sql = 'SELECT SUM('. $self->balance_date_sql(@_).
            ') FROM cust_main WHERE custnum='. $self->custnum;
  sprintf( '%.2f', $self->scalar_sql($sql) );
}

=item balance_pkgnum PKGNUM

Returns the balance for this customer's specific package when using
experimental package balances (total_owed plus total_unrefunded, minus
total_unapplied_credits minus total_unapplied_payments)

=cut

sub balance_pkgnum {
  my( $self, $pkgnum ) = @_;

  sprintf( "%.2f",
      $self->total_owed_pkgnum($pkgnum)
# n/a - refunds aren't part of pkg-balances since they don't apply to invoices
#    + $self->total_unapplied_refunds_pkgnum($pkgnum)
    - $self->total_unapplied_credits_pkgnum($pkgnum)
    - $self->total_unapplied_payments_pkgnum($pkgnum)
  );
}

=item in_transit_payments

Returns the total of requests for payments for this customer pending in 
batches in transit to the bank.  See L<FS::pay_batch> and L<FS::cust_pay_batch>

=cut

sub in_transit_payments {
  my $self = shift;
  my $in_transit_payments = 0;
  foreach my $pay_batch ( qsearch('pay_batch', {
    'status' => 'I',
  } ) ) {
    foreach my $cust_pay_batch ( qsearch('cust_pay_batch', {
      'batchnum' => $pay_batch->batchnum,
      'custnum' => $self->custnum,
    } ) ) {
      $in_transit_payments += $cust_pay_batch->amount;
    }
  }
  sprintf( "%.2f", $in_transit_payments );
}

=item payment_info

Returns a hash of useful information for making a payment.

=over 4

=item balance

Current balance.

=item payby

'CARD' (credit card - automatic), 'DCRD' (credit card - on-demand),
'CHEK' (electronic check - automatic), 'DCHK' (electronic check - on-demand),
'LECB' (Phone bill billing), 'BILL' (billing), or 'COMP' (free).

=back

For credit card transactions:

=over 4

=item card_type 1

=item payname

Exact name on card

=back

For electronic check transactions:

=over 4

=item stateid_state

=back

=cut

sub payment_info {
  my $self = shift;

  my %return = ();

  $return{balance} = $self->balance;

  $return{payname} = $self->payname
                     || ( $self->first. ' '. $self->get('last') );

  $return{$_} = $self->get($_) for qw(address1 address2 city state zip);

  $return{payby} = $self->payby;
  $return{stateid_state} = $self->stateid_state;

  if ( $self->payby =~ /^(CARD|DCRD)$/ ) {
    $return{card_type} = cardtype($self->payinfo);
    $return{payinfo} = $self->paymask;

    @return{'month', 'year'} = $self->paydate_monthyear;

  }

  if ( $self->payby =~ /^(CHEK|DCHK)$/ ) {
    my ($payinfo1, $payinfo2) = split '@', $self->paymask;
    $return{payinfo1} = $payinfo1;
    $return{payinfo2} = $payinfo2;
    $return{paytype}  = $self->paytype;
    $return{paystate} = $self->paystate;

  }

  #doubleclick protection
  my $_date = time;
  $return{paybatch} = "webui-MyAccount-$_date-$$-". rand() * 2**32;

  %return;

}

=item paydate_monthyear

Returns a two-element list consisting of the month and year of this customer's
paydate (credit card expiration date for CARD customers)

=cut

sub paydate_monthyear {
  my $self = shift;
  if ( $self->paydate  =~ /^(\d{4})-(\d{1,2})-\d{1,2}$/ ) { #Pg date format
    ( $2, $1 );
  } elsif ( $self->paydate =~ /^(\d{1,2})-(\d{1,2}-)?(\d{4}$)/ ) {
    ( $1, $3 );
  } else {
    ('', '');
  }
}

=item tax_exemption TAXNAME

=cut

sub tax_exemption {
  my( $self, $taxname ) = @_;

  qsearchs( 'cust_main_exemption', { 'custnum' => $self->custnum,
                                     'taxname' => $taxname,
                                   },
          );
}

=item cust_main_exemption

=cut

sub cust_main_exemption {
  my $self = shift;
  qsearch( 'cust_main_exemption', { 'custnum' => $self->custnum } );
}

=item invoicing_list [ ARRAYREF ]

If an arguement is given, sets these email addresses as invoice recipients
(see L<FS::cust_main_invoice>).  Errors are not fatal and are not reported
(except as warnings), so use check_invoicing_list first.

Returns a list of email addresses (with svcnum entries expanded).

Note: You can clear the invoicing list by passing an empty ARRAYREF.  You can
check it without disturbing anything by passing nothing.

This interface may change in the future.

=cut

sub invoicing_list {
  my( $self, $arrayref ) = @_;

  if ( $arrayref ) {
    my @cust_main_invoice;
    if ( $self->custnum ) {
      @cust_main_invoice = 
        qsearch( 'cust_main_invoice', { 'custnum' => $self->custnum } );
    } else {
      @cust_main_invoice = ();
    }
    foreach my $cust_main_invoice ( @cust_main_invoice ) {
      #warn $cust_main_invoice->destnum;
      unless ( grep { $cust_main_invoice->address eq $_ } @{$arrayref} ) {
        #warn $cust_main_invoice->destnum;
        my $error = $cust_main_invoice->delete;
        warn $error if $error;
      }
    }
    if ( $self->custnum ) {
      @cust_main_invoice = 
        qsearch( 'cust_main_invoice', { 'custnum' => $self->custnum } );
    } else {
      @cust_main_invoice = ();
    }
    my %seen = map { $_->address => 1 } @cust_main_invoice;
    foreach my $address ( @{$arrayref} ) {
      next if exists $seen{$address} && $seen{$address};
      $seen{$address} = 1;
      my $cust_main_invoice = new FS::cust_main_invoice ( {
        'custnum' => $self->custnum,
        'dest'    => $address,
      } );
      my $error = $cust_main_invoice->insert;
      warn $error if $error;
    }
  }
  
  if ( $self->custnum ) {
    map { $_->address }
      qsearch( 'cust_main_invoice', { 'custnum' => $self->custnum } );
  } else {
    ();
  }

}

=item check_invoicing_list ARRAYREF

Checks these arguements as valid input for the invoicing_list method.  If there
is an error, returns the error, otherwise returns false.

=cut

sub check_invoicing_list {
  my( $self, $arrayref ) = @_;

  foreach my $address ( @$arrayref ) {

    if ($address eq 'FAX' and $self->getfield('fax') eq '') {
      return 'Can\'t add FAX invoice destination with a blank FAX number.';
    }

    my $cust_main_invoice = new FS::cust_main_invoice ( {
      'custnum' => $self->custnum,
      'dest'    => $address,
    } );
    my $error = $self->custnum
                ? $cust_main_invoice->check
                : $cust_main_invoice->checkdest
    ;
    return $error if $error;

  }

  return "Email address required"
    if $conf->exists('cust_main-require_invoicing_list_email')
    && ! grep { $_ !~ /^([A-Z]+)$/ } @$arrayref;

  '';
}

=item set_default_invoicing_list

Sets the invoicing list to all accounts associated with this customer,
overwriting any previous invoicing list.

=cut

sub set_default_invoicing_list {
  my $self = shift;
  $self->invoicing_list($self->all_emails);
}

=item all_emails

Returns the email addresses of all accounts provisioned for this customer.

=cut

sub all_emails {
  my $self = shift;
  my %list;
  foreach my $cust_pkg ( $self->all_pkgs ) {
    my @cust_svc = qsearch('cust_svc', { 'pkgnum' => $cust_pkg->pkgnum } );
    my @svc_acct =
      map { qsearchs('svc_acct', { 'svcnum' => $_->svcnum } ) }
        grep { qsearchs('svc_acct', { 'svcnum' => $_->svcnum } ) }
          @cust_svc;
    $list{$_}=1 foreach map { $_->email } @svc_acct;
  }
  keys %list;
}

=item invoicing_list_addpost

Adds postal invoicing to this customer.  If this customer is already configured
to receive postal invoices, does nothing.

=cut

sub invoicing_list_addpost {
  my $self = shift;
  return if grep { $_ eq 'POST' } $self->invoicing_list;
  my @invoicing_list = $self->invoicing_list;
  push @invoicing_list, 'POST';
  $self->invoicing_list(\@invoicing_list);
}

=item invoicing_list_emailonly

Returns the list of email invoice recipients (invoicing_list without non-email
destinations such as POST and FAX).

=cut

sub invoicing_list_emailonly {
  my $self = shift;
  warn "$me invoicing_list_emailonly called"
    if $DEBUG;
  grep { $_ !~ /^([A-Z]+)$/ } $self->invoicing_list;
}

=item invoicing_list_emailonly_scalar

Returns the list of email invoice recipients (invoicing_list without non-email
destinations such as POST and FAX) as a comma-separated scalar.

=cut

sub invoicing_list_emailonly_scalar {
  my $self = shift;
  warn "$me invoicing_list_emailonly_scalar called"
    if $DEBUG;
  join(', ', $self->invoicing_list_emailonly);
}

=item referral_custnum_cust_main

Returns the customer who referred this customer (or the empty string, if
this customer was not referred).

Note the difference with referral_cust_main method: This method,
referral_custnum_cust_main returns the single customer (if any) who referred
this customer, while referral_cust_main returns an array of customers referred
BY this customer.

=cut

sub referral_custnum_cust_main {
  my $self = shift;
  return '' unless $self->referral_custnum;
  qsearchs('cust_main', { 'custnum' => $self->referral_custnum } );
}

=item referral_cust_main [ DEPTH [ EXCLUDE_HASHREF ] ]

Returns an array of customers referred by this customer (referral_custnum set
to this custnum).  If DEPTH is given, recurses up to the given depth, returning
customers referred by customers referred by this customer and so on, inclusive.
The default behavior is DEPTH 1 (no recursion).

Note the difference with referral_custnum_cust_main method: This method,
referral_cust_main, returns an array of customers referred BY this customer,
while referral_custnum_cust_main returns the single customer (if any) who
referred this customer.

=cut

sub referral_cust_main {
  my $self = shift;
  my $depth = @_ ? shift : 1;
  my $exclude = @_ ? shift : {};

  my @cust_main =
    map { $exclude->{$_->custnum}++; $_; }
      grep { ! $exclude->{ $_->custnum } }
        qsearch( 'cust_main', { 'referral_custnum' => $self->custnum } );

  if ( $depth > 1 ) {
    push @cust_main,
      map { $_->referral_cust_main($depth-1, $exclude) }
        @cust_main;
  }

  @cust_main;
}

=item referral_cust_main_ncancelled

Same as referral_cust_main, except only returns customers with uncancelled
packages.

=cut

sub referral_cust_main_ncancelled {
  my $self = shift;
  grep { scalar($_->ncancelled_pkgs) } $self->referral_cust_main;
}

=item referral_cust_pkg [ DEPTH ]

Like referral_cust_main, except returns a flat list of all unsuspended (and
uncancelled) packages for each customer.  The number of items in this list may
be useful for commission calculations (perhaps after a C<grep { my $pkgpart = $_->pkgpart; grep { $_ == $pkgpart } @commission_worthy_pkgparts> } $cust_main-> ).

=cut

sub referral_cust_pkg {
  my $self = shift;
  my $depth = @_ ? shift : 1;

  map { $_->unsuspended_pkgs }
    grep { $_->unsuspended_pkgs }
      $self->referral_cust_main($depth);
}

=item referring_cust_main

Returns the single cust_main record for the customer who referred this customer
(referral_custnum), or false.

=cut

sub referring_cust_main {
  my $self = shift;
  return '' unless $self->referral_custnum;
  qsearchs('cust_main', { 'custnum' => $self->referral_custnum } );
}

=item credit AMOUNT, REASON [ , OPTION => VALUE ... ]

Applies a credit to this customer.  If there is an error, returns the error,
otherwise returns false.

REASON can be a text string, an FS::reason object, or a scalar reference to
a reasonnum.  If a text string, it will be automatically inserted as a new
reason, and a 'reason_type' option must be passed to indicate the
FS::reason_type for the new reason.

An I<addlinfo> option may be passed to set the credit's I<addlinfo> field.

Any other options are passed to FS::cust_credit::insert.

=cut

sub credit {
  my( $self, $amount, $reason, %options ) = @_;

  my $cust_credit = new FS::cust_credit {
    'custnum' => $self->custnum,
    'amount'  => $amount,
  };

  if ( ref($reason) ) {

    if ( ref($reason) eq 'SCALAR' ) {
      $cust_credit->reasonnum( $$reason );
    } else {
      $cust_credit->reasonnum( $reason->reasonnum );
    }

  } else {
    $cust_credit->set('reason', $reason)
  }

  for (qw( addlinfo eventnum )) {
    $cust_credit->$_( delete $options{$_} )
      if exists($options{$_});
  }

  $cust_credit->insert(%options);

}

=item charge HASHREF || AMOUNT [ PKG [ COMMENT [ TAXCLASS ] ] ]

Creates a one-time charge for this customer.  If there is an error, returns
the error, otherwise returns false.

New-style, with a hashref of options:

  my $error = $cust_main->charge(
                                  {
                                    'amount'     => 54.32,
                                    'quantity'   => 1,
                                    'start_date' => str2time('7/4/2009'),
                                    'pkg'        => 'Description',
                                    'comment'    => 'Comment',
                                    'additional' => [], #extra invoice detail
                                    'classnum'   => 1,  #pkg_class

                                    'setuptax'   => '', # or 'Y' for tax exempt

                                    #internal taxation
                                    'taxclass'   => 'Tax class',

                                    #vendor taxation
                                    'taxproduct' => 2,  #part_pkg_taxproduct
                                    'override'   => {}, #XXX describe

                                    #will be filled in with the new object
                                    'cust_pkg_ref' => \$cust_pkg,

                                    #generate an invoice immediately
                                    'bill_now' => 0,
                                    'invoice_terms' => '', #with these terms
                                  }
                                );

Old-style:

  my $error = $cust_main->charge( 54.32, 'Description', 'Comment', 'Tax class' );

=cut

sub charge {
  my $self = shift;
  my ( $amount, $quantity, $start_date, $classnum );
  my ( $pkg, $comment, $additional );
  my ( $setuptax, $taxclass );   #internal taxes
  my ( $taxproduct, $override ); #vendor (CCH) taxes
  my $no_auto = '';
  my $cust_pkg_ref = '';
  my ( $bill_now, $invoice_terms ) = ( 0, '' );
  if ( ref( $_[0] ) ) {
    $amount     = $_[0]->{amount};
    $quantity   = exists($_[0]->{quantity}) ? $_[0]->{quantity} : 1;
    $start_date = exists($_[0]->{start_date}) ? $_[0]->{start_date} : '';
    $no_auto    = exists($_[0]->{no_auto}) ? $_[0]->{no_auto} : '';
    $pkg        = exists($_[0]->{pkg}) ? $_[0]->{pkg} : 'One-time charge';
    $comment    = exists($_[0]->{comment}) ? $_[0]->{comment}
                                           : '$'. sprintf("%.2f",$amount);
    $setuptax   = exists($_[0]->{setuptax}) ? $_[0]->{setuptax} : '';
    $taxclass   = exists($_[0]->{taxclass}) ? $_[0]->{taxclass} : '';
    $classnum   = exists($_[0]->{classnum}) ? $_[0]->{classnum} : '';
    $additional = $_[0]->{additional} || [];
    $taxproduct = $_[0]->{taxproductnum};
    $override   = { '' => $_[0]->{tax_override} };
    $cust_pkg_ref = exists($_[0]->{cust_pkg_ref}) ? $_[0]->{cust_pkg_ref} : '';
    $bill_now = exists($_[0]->{bill_now}) ? $_[0]->{bill_now} : '';
    $invoice_terms = exists($_[0]->{invoice_terms}) ? $_[0]->{invoice_terms} : '';
  } else {
    $amount     = shift;
    $quantity   = 1;
    $start_date = '';
    $pkg        = @_ ? shift : 'One-time charge';
    $comment    = @_ ? shift : '$'. sprintf("%.2f",$amount);
    $setuptax   = '';
    $taxclass   = @_ ? shift : '';
    $additional = [];
  }

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  my $part_pkg = new FS::part_pkg ( {
    'pkg'           => $pkg,
    'comment'       => $comment,
    'plan'          => 'flat',
    'freq'          => 0,
    'disabled'      => 'Y',
    'classnum'      => ( $classnum ? $classnum : '' ),
    'setuptax'      => $setuptax,
    'taxclass'      => $taxclass,
    'taxproductnum' => $taxproduct,
  } );

  my %options = ( ( map { ("additional_info$_" => $additional->[$_] ) }
                        ( 0 .. @$additional - 1 )
                  ),
                  'additional_count' => scalar(@$additional),
                  'setup_fee' => $amount,
                );

  my $error = $part_pkg->insert( options       => \%options,
                                 tax_overrides => $override,
                               );
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return $error;
  }

  my $pkgpart = $part_pkg->pkgpart;
  my %type_pkgs = ( 'typenum' => $self->agent->typenum, 'pkgpart' => $pkgpart );
  unless ( qsearchs('type_pkgs', \%type_pkgs ) ) {
    my $type_pkgs = new FS::type_pkgs \%type_pkgs;
    $error = $type_pkgs->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
  }

  my $cust_pkg = new FS::cust_pkg ( {
    'custnum'    => $self->custnum,
    'pkgpart'    => $pkgpart,
    'quantity'   => $quantity,
    'start_date' => $start_date,
    'no_auto'    => $no_auto,
  } );

  $error = $cust_pkg->insert;
  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    return $error;
  } elsif ( $cust_pkg_ref ) {
    ${$cust_pkg_ref} = $cust_pkg;
  }

  if ( $bill_now ) {
    my $error = $self->bill( 'invoice_terms' => $invoice_terms,
                             'pkg_list'      => [ $cust_pkg ],
                           );
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }   
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  return '';

}

#=item charge_postal_fee
#
#Applies a one time charge this customer.  If there is an error,
#returns the error, returns the cust_pkg charge object or false
#if there was no charge.
#
#=cut
#
# This should be a customer event.  For that to work requires that bill
# also be a customer event.

sub charge_postal_fee {
  my $self = shift;

  my $pkgpart = $conf->config('postal_invoice-fee_pkgpart');
  return '' unless ($pkgpart && grep { $_ eq 'POST' } $self->invoicing_list);

  my $cust_pkg = new FS::cust_pkg ( {
    'custnum'  => $self->custnum,
    'pkgpart'  => $pkgpart,
    'quantity' => 1,
  } );

  my $error = $cust_pkg->insert;
  $error ? $error : $cust_pkg;
}

=item cust_bill

Returns all the invoices (see L<FS::cust_bill>) for this customer.

=cut

sub cust_bill {
  my $self = shift;
  map { $_ } #return $self->num_cust_bill unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch('cust_bill', { 'custnum' => $self->custnum, } )
}

=item open_cust_bill

Returns all the open (owed > 0) invoices (see L<FS::cust_bill>) for this
customer.

=cut

sub open_cust_bill {
  my $self = shift;

  qsearch({
    'table'     => 'cust_bill',
    'hashref'   => { 'custnum' => $self->custnum, },
    'extra_sql' => ' AND '. FS::cust_bill->owed_sql. ' > 0',
    'order_by'  => 'ORDER BY _date ASC',
  });

}

=item cust_statements

Returns all the statements (see L<FS::cust_statement>) for this customer.

=cut

sub cust_statement {
  my $self = shift;
  map { $_ } #return $self->num_cust_statement unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch('cust_statement', { 'custnum' => $self->custnum, } )
}

=item cust_credit

Returns all the credits (see L<FS::cust_credit>) for this customer.

=cut

sub cust_credit {
  my $self = shift;
  map { $_ } #return $self->num_cust_credit unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch( 'cust_credit', { 'custnum' => $self->custnum } )
}

=item cust_credit_pkgnum

Returns all the credits (see L<FS::cust_credit>) for this customer's specific
package when using experimental package balances.

=cut

sub cust_credit_pkgnum {
  my( $self, $pkgnum ) = @_;
  map { $_ } #return $self->num_cust_credit_pkgnum($pkgnum) unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch( 'cust_credit', { 'custnum' => $self->custnum,
                              'pkgnum'  => $pkgnum,
                            }
    );
}

=item cust_pay

Returns all the payments (see L<FS::cust_pay>) for this customer.

=cut

sub cust_pay {
  my $self = shift;
  return $self->num_cust_pay unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch( 'cust_pay', { 'custnum' => $self->custnum } )
}

=item num_cust_pay

Returns the number of payments (see L<FS::cust_pay>) for this customer.  Also
called automatically when the cust_pay method is used in a scalar context.

=cut

sub num_cust_pay {
  my $self = shift;
  my $sql = "SELECT COUNT(*) FROM cust_pay WHERE custnum = ?";
  my $sth = dbh->prepare($sql) or die dbh->errstr;
  $sth->execute($self->custnum) or die $sth->errstr;
  $sth->fetchrow_arrayref->[0];
}

=item cust_pay_pkgnum

Returns all the payments (see L<FS::cust_pay>) for this customer's specific
package when using experimental package balances.

=cut

sub cust_pay_pkgnum {
  my( $self, $pkgnum ) = @_;
  map { $_ } #return $self->num_cust_pay_pkgnum($pkgnum) unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch( 'cust_pay', { 'custnum' => $self->custnum,
                           'pkgnum'  => $pkgnum,
                         }
    );
}

=item cust_pay_void

Returns all voided payments (see L<FS::cust_pay_void>) for this customer.

=cut

sub cust_pay_void {
  my $self = shift;
  map { $_ } #return $self->num_cust_pay_void unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch( 'cust_pay_void', { 'custnum' => $self->custnum } )
}

=item cust_pay_batch

Returns all batched payments (see L<FS::cust_pay_void>) for this customer.

=cut

sub cust_pay_batch {
  my $self = shift;
  map { $_ } #return $self->num_cust_pay_batch unless wantarray;
  sort { $a->paybatchnum <=> $b->paybatchnum }
    qsearch( 'cust_pay_batch', { 'custnum' => $self->custnum } )
}

=item cust_pay_pending

Returns all pending payments (see L<FS::cust_pay_pending>) for this customer
(without status "done").

=cut

sub cust_pay_pending {
  my $self = shift;
  return $self->num_cust_pay_pending unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch( 'cust_pay_pending', {
                                   'custnum' => $self->custnum,
                                   'status'  => { op=>'!=', value=>'done' },
                                 },
           );
}

=item cust_pay_pending_attempt

Returns all payment attempts / declined payments for this customer, as pending
payments objects (see L<FS::cust_pay_pending>), with status "done" but without
a corresponding payment (see L<FS::cust_pay>).

=cut

sub cust_pay_pending_attempt {
  my $self = shift;
  return $self->num_cust_pay_pending_attempt unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch( 'cust_pay_pending', {
                                   'custnum' => $self->custnum,
                                   'status'  => 'done',
                                   'paynum'  => '',
                                 },
           );
}

=item num_cust_pay_pending

Returns the number of pending payments (see L<FS::cust_pay_pending>) for this
customer (without status "done").  Also called automatically when the
cust_pay_pending method is used in a scalar context.

=cut

sub num_cust_pay_pending {
  my $self = shift;
  $self->scalar_sql(
    " SELECT COUNT(*) FROM cust_pay_pending ".
      " WHERE custnum = ? AND status != 'done' ",
    $self->custnum
  );
}

=item num_cust_pay_pending_attempt

Returns the number of pending payments (see L<FS::cust_pay_pending>) for this
customer, with status "done" but without a corresp.  Also called automatically when the
cust_pay_pending method is used in a scalar context.

=cut

sub num_cust_pay_pending_attempt {
  my $self = shift;
  $self->scalar_sql(
    " SELECT COUNT(*) FROM cust_pay_pending ".
      " WHERE custnum = ? AND status = 'done' AND paynum IS NULL",
    $self->custnum
  );
}

=item cust_refund

Returns all the refunds (see L<FS::cust_refund>) for this customer.

=cut

sub cust_refund {
  my $self = shift;
  map { $_ } #return $self->num_cust_refund unless wantarray;
  sort { $a->_date <=> $b->_date }
    qsearch( 'cust_refund', { 'custnum' => $self->custnum } )
}

=item display_custnum

Returns the displayed customer number for this customer: agent_custid if
cust_main-default_agent_custid is set and it has a value, custnum otherwise.

=cut

sub display_custnum {
  my $self = shift;
  if ( $conf->exists('cust_main-default_agent_custid') && $self->agent_custid ){
    return $self->agent_custid;
  } else {
    return $self->custnum;
  }
}

=item name

Returns a name string for this customer, either "Company (Last, First)" or
"Last, First".

=cut

sub name {
  my $self = shift;
  my $name = $self->contact;
  $name = $self->company. " ($name)" if $self->company;
  $name;
}

=item ship_name

Returns a name string for this (service/shipping) contact, either
"Company (Last, First)" or "Last, First".

=cut

sub ship_name {
  my $self = shift;
  if ( $self->get('ship_last') ) { 
    my $name = $self->ship_contact;
    $name = $self->ship_company. " ($name)" if $self->ship_company;
    $name;
  } else {
    $self->name;
  }
}

=item name_short

Returns a name string for this customer, either "Company" or "First Last".

=cut

sub name_short {
  my $self = shift;
  $self->company !~ /^\s*$/ ? $self->company : $self->contact_firstlast;
}

=item ship_name_short

Returns a name string for this (service/shipping) contact, either "Company"
or "First Last".

=cut

sub ship_name_short {
  my $self = shift;
  if ( $self->get('ship_last') ) { 
    $self->ship_company !~ /^\s*$/
      ? $self->ship_company
      : $self->ship_contact_firstlast;
  } else {
    $self->name_company_or_firstlast;
  }
}

=item contact

Returns this customer's full (billing) contact name only, "Last, First"

=cut

sub contact {
  my $self = shift;
  $self->get('last'). ', '. $self->first;
}

=item ship_contact

Returns this customer's full (shipping) contact name only, "Last, First"

=cut

sub ship_contact {
  my $self = shift;
  $self->get('ship_last')
    ? $self->get('ship_last'). ', '. $self->ship_first
    : $self->contact;
}

=item contact_firstlast

Returns this customers full (billing) contact name only, "First Last".

=cut

sub contact_firstlast {
  my $self = shift;
  $self->first. ' '. $self->get('last');
}

=item ship_contact_firstlast

Returns this customer's full (shipping) contact name only, "First Last".

=cut

sub ship_contact_firstlast {
  my $self = shift;
  $self->get('ship_last')
    ? $self->first. ' '. $self->get('ship_last')
    : $self->contact_firstlast;
}

=item country_full

Returns this customer's full country name

=cut

sub country_full {
  my $self = shift;
  code2country($self->country);
}

=item geocode DATA_VENDOR

Returns a value for the customer location as encoded by DATA_VENDOR.
Currently this only makes sense for "CCH" as DATA_VENDOR.

=cut

sub geocode {
  my ($self, $data_vendor) = (shift, shift);  #always cch for now

  my $geocode = $self->get('geocode');  #XXX only one data_vendor for geocode
  return $geocode if $geocode;

  my $prefix = ( $conf->exists('tax-ship_address') && length($self->ship_last) )
               ? 'ship_'
               : '';

  my($zip,$plus4) = split /-/, $self->get("${prefix}zip")
    if $self->country eq 'US';

  $zip ||= '';
  $plus4 ||= '';
  #CCH specific location stuff
  my $extra_sql = "AND plus4lo <= '$plus4' AND plus4hi >= '$plus4'";

  my @cust_tax_location =
    qsearch( {
               'table'     => 'cust_tax_location', 
               'hashref'   => { 'zip' => $zip, 'data_vendor' => $data_vendor },
               'extra_sql' => $extra_sql,
               'order_by'  => 'ORDER BY plus4hi',#overlapping with distinct ends
             }
           );
  $geocode = $cust_tax_location[0]->geocode
    if scalar(@cust_tax_location);

  $geocode;
}

=item cust_status

=item status

Returns a status string for this customer, currently:

=over 4

=item prospect - No packages have ever been ordered

=item ordered - Recurring packages all are new (not yet billed).

=item active - One or more recurring packages is active

=item inactive - No active recurring packages, but otherwise unsuspended/uncancelled (the inactive status is new - previously inactive customers were mis-identified as cancelled)

=item suspended - All non-cancelled recurring packages are suspended

=item cancelled - All recurring packages are cancelled

=back

=cut

sub status { shift->cust_status(@_); }

sub cust_status {
  my $self = shift;
  # prospect ordered active inactive suspended cancelled
  for my $status ( FS::cust_main->statuses() ) {
    my $method = $status.'_sql';
    my $numnum = ( my $sql = $self->$method() ) =~ s/cust_main\.custnum/?/g;
    my $sth = dbh->prepare("SELECT $sql") or die dbh->errstr;
    $sth->execute( ($self->custnum) x $numnum )
      or die "Error executing 'SELECT $sql': ". $sth->errstr;
    return $status if $sth->fetchrow_arrayref->[0];
  }
}

=item ucfirst_cust_status

=item ucfirst_status

Returns the status with the first character capitalized.

=cut

sub ucfirst_status { shift->ucfirst_cust_status(@_); }

sub ucfirst_cust_status {
  my $self = shift;
  ucfirst($self->cust_status);
}

=item statuscolor

Returns a hex triplet color string for this customer's status.

=cut

use vars qw(%statuscolor);
tie %statuscolor, 'Tie::IxHash',
  'prospect'  => '7e0079', #'000000', #black?  naw, purple
  'active'    => '00CC00', #green
  'ordered'   => '009999', #teal? cyan?
  'inactive'  => '0000CC', #blue
  'suspended' => 'FF9900', #yellow
  'cancelled' => 'FF0000', #red
;

sub statuscolor { shift->cust_statuscolor(@_); }

sub cust_statuscolor {
  my $self = shift;
  $statuscolor{$self->cust_status};
}

=item tickets

Returns an array of hashes representing the customer's RT tickets.

=cut

sub tickets {
  my $self = shift;

  my $num = $conf->config('cust_main-max_tickets') || 10;
  my @tickets = ();

  if ( $conf->config('ticket_system') ) {
    unless ( $conf->config('ticket_system-custom_priority_field') ) {

      @tickets = @{ FS::TicketSystem->customer_tickets($self->custnum, $num) };

    } else {

      foreach my $priority (
        $conf->config('ticket_system-custom_priority_field-values'), ''
      ) {
        last if scalar(@tickets) >= $num;
        push @tickets, 
          @{ FS::TicketSystem->customer_tickets( $self->custnum,
                                                 $num - scalar(@tickets),
                                                 $priority,
                                               )
           };
      }
    }
  }
  (@tickets);
}

# Return services representing svc_accts in customer support packages
sub support_services {
  my $self = shift;
  my %packages = map { $_ => 1 } $conf->config('support_packages');

  grep { $_->pkg_svc && $_->pkg_svc->primary_svc eq 'Y' }
    grep { $_->part_svc->svcdb eq 'svc_acct' }
    map { $_->cust_svc }
    grep { exists $packages{ $_->pkgpart } }
    $self->ncancelled_pkgs;

}

# Return a list of latitude/longitude for one of the services (if any)
sub service_coordinates {
  my $self = shift;

  my @svc_X = 
    grep { $_->latitude && $_->longitude }
    map { $_->svc_x }
    map { $_->cust_svc }
    $self->ncancelled_pkgs;

  scalar(@svc_X) ? ( $svc_X[0]->latitude, $svc_X[0]->longitude ) : ()
}

=item masked FIELD

Returns a masked version of the named field

=cut

sub masked {
my ($self,$field) = @_;

# Show last four

'x'x(length($self->getfield($field))-4).
  substr($self->getfield($field), (length($self->getfield($field))-4));

}

=back

=head1 CLASS METHODS

=over 4

=item statuses

Class method that returns the list of possible status strings for customers
(see L<the status method|/status>).  For example:

  @statuses = FS::cust_main->statuses();

=cut

sub statuses {
  #my $self = shift; #could be class...
  keys %statuscolor;
}

=item prospect_sql

Returns an SQL expression identifying prospective cust_main records (customers
with no packages ever ordered)

=cut

use vars qw($select_count_pkgs);
$select_count_pkgs =
  "SELECT COUNT(*) FROM cust_pkg
    WHERE cust_pkg.custnum = cust_main.custnum";

sub select_count_pkgs_sql {
  $select_count_pkgs;
}

sub prospect_sql {
  " 0 = ( $select_count_pkgs ) ";
}

=item ordered_sql

Returns an SQL expression identifying ordered cust_main records (customers with
recurring packages not yet setup).

=cut

sub ordered_sql {
  FS::cust_main->none_active_sql.
  " AND 0 < ( $select_count_pkgs AND ". FS::cust_pkg->ordered_sql. " ) ";
}

=item active_sql

Returns an SQL expression identifying active cust_main records (customers with
active recurring packages).

=cut

sub active_sql {
  " 0 < ( $select_count_pkgs AND ". FS::cust_pkg->active_sql. " ) ";
}

=item none_active_sql

Returns an SQL expression identifying cust_main records with no active
recurring packages.  This includes customers of status prospect, ordered,
inactive, and suspended.

=cut

sub none_active_sql {
  " 0 = ( $select_count_pkgs AND ". FS::cust_pkg->active_sql. " ) ";
}

=item inactive_sql

Returns an SQL expression identifying inactive cust_main records (customers with
no active recurring packages, but otherwise unsuspended/uncancelled).

=cut

sub inactive_sql {
  FS::cust_main->none_active_sql.
  " AND 0 < ( $select_count_pkgs AND ". FS::cust_pkg->inactive_sql. " ) ";
}

=item susp_sql
=item suspended_sql

Returns an SQL expression identifying suspended cust_main records.

=cut


sub suspended_sql { susp_sql(@_); }
sub susp_sql {
  FS::cust_main->none_active_sql.
  " AND 0 < ( $select_count_pkgs AND ". FS::cust_pkg->suspended_sql. " ) ";
}

=item cancel_sql
=item cancelled_sql

Returns an SQL expression identifying cancelled cust_main records.

=cut

sub cancelled_sql { cancel_sql(@_); }
sub cancel_sql {

  my $recurring_sql = FS::cust_pkg->recurring_sql;
  my $cancelled_sql = FS::cust_pkg->cancelled_sql;

  "
        0 < ( $select_count_pkgs )
    AND 0 < ( $select_count_pkgs AND $recurring_sql AND $cancelled_sql   )
    AND 0 = ( $select_count_pkgs AND $recurring_sql
                  AND ( cust_pkg.cancel IS NULL OR cust_pkg.cancel = 0 )
            )
    AND 0 = (  $select_count_pkgs AND ". FS::cust_pkg->inactive_sql. " )
  ";

}

=item uncancel_sql
=item uncancelled_sql

Returns an SQL expression identifying un-cancelled cust_main records.

=cut

sub uncancelled_sql { uncancel_sql(@_); }
sub uncancel_sql { "
  ( 0 < ( $select_count_pkgs
                   AND ( cust_pkg.cancel IS NULL
                         OR cust_pkg.cancel = 0
                       )
        )
    OR 0 = ( $select_count_pkgs )
  )
"; }

=item balance_sql

Returns an SQL fragment to retreive the balance.

=cut

sub balance_sql { "
    ( SELECT COALESCE( SUM(charged), 0 ) FROM cust_bill
        WHERE cust_bill.custnum   = cust_main.custnum     )
  - ( SELECT COALESCE( SUM(paid),    0 ) FROM cust_pay
        WHERE cust_pay.custnum    = cust_main.custnum     )
  - ( SELECT COALESCE( SUM(amount),  0 ) FROM cust_credit
        WHERE cust_credit.custnum = cust_main.custnum     )
  + ( SELECT COALESCE( SUM(refund),  0 ) FROM cust_refund
        WHERE cust_refund.custnum = cust_main.custnum     )
"; }

=item balance_date_sql [ START_TIME [ END_TIME [ OPTION => VALUE ... ] ] ]

Returns an SQL fragment to retreive the balance for this customer, optionally
considering invoices with date earlier than START_TIME, and not
later than END_TIME (total_owed_date minus total_unapplied_credits minus
total_unapplied_payments).

Times are specified as SQL fragments or numeric
UNIX timestamps; see L<perlfunc/"time">).  Also see L<Time::Local> and
L<Date::Parse> for conversion functions.  The empty string can be passed
to disable that time constraint completely.

Available options are:

=over 4

=item unapplied_date

set to true to disregard unapplied credits, payments and refunds outside the specified time period - by default the time period restriction only applies to invoices (useful for reporting, probably a bad idea for event triggering)

=item total

(unused.  obsolete?)
set to true to remove all customer comparison clauses, for totals

=item where

(unused.  obsolete?)
WHERE clause hashref (elements "AND"ed together) (typically used with the total option)

=item join

(unused.  obsolete?)
JOIN clause (typically used with the total option)

=item cutoff

An absolute cutoff time.  Payments, credits, and refunds I<applied> after this 
time will be ignored.  Note that START_TIME and END_TIME only limit the date 
range for invoices and I<unapplied> payments, credits, and refunds.

=back

=cut

sub balance_date_sql {
  my( $class, $start, $end, %opt ) = @_;

  my $cutoff = $opt{'cutoff'};

  my $owed         = FS::cust_bill->owed_sql($cutoff);
  my $unapp_refund = FS::cust_refund->unapplied_sql($cutoff);
  my $unapp_credit = FS::cust_credit->unapplied_sql($cutoff);
  my $unapp_pay    = FS::cust_pay->unapplied_sql($cutoff);

  my $j = $opt{'join'} || '';

  my $owed_wh   = $class->_money_table_where( 'cust_bill',   $start,$end,%opt );
  my $refund_wh = $class->_money_table_where( 'cust_refund', $start,$end,%opt );
  my $credit_wh = $class->_money_table_where( 'cust_credit', $start,$end,%opt );
  my $pay_wh    = $class->_money_table_where( 'cust_pay',    $start,$end,%opt );

  "   ( SELECT COALESCE(SUM($owed),         0) FROM cust_bill   $j $owed_wh   )
    + ( SELECT COALESCE(SUM($unapp_refund), 0) FROM cust_refund $j $refund_wh )
    - ( SELECT COALESCE(SUM($unapp_credit), 0) FROM cust_credit $j $credit_wh )
    - ( SELECT COALESCE(SUM($unapp_pay),    0) FROM cust_pay    $j $pay_wh    )
  ";

}

=item unapplied_payments_date_sql START_TIME [ END_TIME ]

Returns an SQL fragment to retreive the total unapplied payments for this
customer, only considering invoices with date earlier than START_TIME, and
optionally not later than END_TIME.

Times are specified as SQL fragments or numeric
UNIX timestamps; see L<perlfunc/"time">).  Also see L<Time::Local> and
L<Date::Parse> for conversion functions.  The empty string can be passed
to disable that time constraint completely.

Available options are:

=cut

sub unapplied_payments_date_sql {
  my( $class, $start, $end, %opt ) = @_;

  my $cutoff = $opt{'cutoff'};

  my $unapp_pay    = FS::cust_pay->unapplied_sql($cutoff);

  my $pay_where = $class->_money_table_where( 'cust_pay', $start, $end,
                                                          'unapplied_date'=>1 );

  " ( SELECT COALESCE(SUM($unapp_pay), 0) FROM cust_pay $pay_where ) ";
}

=item _money_table_where TABLE START_TIME [ END_TIME [ OPTION => VALUE ... ] ]

Helper method for balance_date_sql; name (and usage) subject to change
(suggestions welcome).

Returns a WHERE clause for the specified monetary TABLE (cust_bill,
cust_refund, cust_credit or cust_pay).

If TABLE is "cust_bill" or the unapplied_date option is true, only
considers records with date earlier than START_TIME, and optionally not
later than END_TIME .

=cut

sub _money_table_where {
  my( $class, $table, $start, $end, %opt ) = @_;

  my @where = ();
  push @where, "cust_main.custnum = $table.custnum" unless $opt{'total'};
  if ( $table eq 'cust_bill' || $opt{'unapplied_date'} ) {
    push @where, "$table._date <= $start" if defined($start) && length($start);
    push @where, "$table._date >  $end"   if defined($end)   && length($end);
  }
  push @where, @{$opt{'where'}} if $opt{'where'};
  my $where = scalar(@where) ? 'WHERE '. join(' AND ', @where ) : '';

  $where;

}

#for dyanmic FS::$table->search in httemplate/misc/email_customers.html
use FS::cust_main::Search;
sub search {
  my $class = shift;
  FS::cust_main::Search->search(@_);
}

=back

=head1 SUBROUTINES

=over 4

=item append_fuzzyfiles FIRSTNAME LASTNAME COMPANY ADDRESS1

=cut

use FS::cust_main::Search;
sub append_fuzzyfiles {
  #my( $first, $last, $company ) = @_;

  FS::cust_main::Search::check_and_rebuild_fuzzyfiles();

  use Fcntl qw(:flock);

  my $dir = $FS::UID::conf_dir. "/cache.". $FS::UID::datasrc;

  foreach my $field (@fuzzyfields) {
    my $value = shift;

    if ( $value ) {

      open(CACHE,">>$dir/cust_main.$field")
        or die "can't open $dir/cust_main.$field: $!";
      flock(CACHE,LOCK_EX)
        or die "can't lock $dir/cust_main.$field: $!";

      print CACHE "$value\n";

      flock(CACHE,LOCK_UN)
        or die "can't unlock $dir/cust_main.$field: $!";
      close CACHE;
    }

  }

  1;
}

=item batch_charge

=cut

sub batch_charge {
  my $param = shift;
  #warn join('-',keys %$param);
  my $fh = $param->{filehandle};
  my $agentnum = $param->{agentnum};
  my $format = $param->{format};

  my $extra_sql = ' AND '. $FS::CurrentUser::CurrentUser->agentnums_sql;

  my @fields;
  if ( $format eq 'simple' ) {
    @fields = qw( custnum agent_custid amount pkg );
  } else {
    die "unknown format $format";
  }

  eval "use Text::CSV_XS;";
  die $@ if $@;

  my $csv = new Text::CSV_XS;
  #warn $csv;
  #warn $fh;

  my $imported = 0;
  #my $columns;

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;
  
  #while ( $columns = $csv->getline($fh) ) {
  my $line;
  while ( defined($line=<$fh>) ) {

    $csv->parse($line) or do {
      $dbh->rollback if $oldAutoCommit;
      return "can't parse: ". $csv->error_input();
    };

    my @columns = $csv->fields();
    #warn join('-',@columns);

    my %row = ();
    foreach my $field ( @fields ) {
      $row{$field} = shift @columns;
    }

    if ( $row{custnum} && $row{agent_custid} ) {
      dbh->rollback if $oldAutoCommit;
      return "can't specify custnum with agent_custid $row{agent_custid}";
    }

    my %hash = ();
    if ( $row{agent_custid} && $agentnum ) {
      %hash = ( 'agent_custid' => $row{agent_custid},
                'agentnum'     => $agentnum,
              );
    }

    if ( $row{custnum} ) {
      %hash = ( 'custnum' => $row{custnum} );
    }

    unless ( scalar(keys %hash) ) {
      $dbh->rollback if $oldAutoCommit;
      return "can't find customer without custnum or agent_custid and agentnum";
    }

    my $cust_main = qsearchs('cust_main', { %hash } );
    unless ( $cust_main ) {
      $dbh->rollback if $oldAutoCommit;
      my $custnum = $row{custnum} || $row{agent_custid};
      return "unknown custnum $custnum";
    }

    if ( $row{'amount'} > 0 ) {
      my $error = $cust_main->charge($row{'amount'}, $row{'pkg'});
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return $error;
      }
      $imported++;
    } elsif ( $row{'amount'} < 0 ) {
      my $error = $cust_main->credit( sprintf( "%.2f", 0-$row{'amount'} ),
                                      $row{'pkg'}                         );
      if ( $error ) {
        $dbh->rollback if $oldAutoCommit;
        return $error;
      }
      $imported++;
    } else {
      #hmm?
    }

  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;

  return "Empty file!" unless $imported;

  ''; #no error

}

=item notify CUSTOMER_OBJECT TEMPLATE_NAME OPTIONS

Deprecated.  Use event notification and message templates 
(L<FS::msg_template>) instead.

Sends a templated email notification to the customer (see L<Text::Template>).

OPTIONS is a hash and may include

I<from> - the email sender (default is invoice_from)

I<to> - comma-separated scalar or arrayref of recipients 
   (default is invoicing_list)

I<subject> - The subject line of the sent email notification
   (default is "Notice from company_name")

I<extra_fields> - a hashref of name/value pairs which will be substituted
   into the template

The following variables are vavailable in the template.

I<$first> - the customer first name
I<$last> - the customer last name
I<$company> - the customer company
I<$payby> - a description of the method of payment for the customer
            # would be nice to use FS::payby::shortname
I<$payinfo> - the account information used to collect for this customer
I<$expdate> - the expiration of the customer payment in seconds from epoch

=cut

sub notify {
  my ($self, $template, %options) = @_;

  return unless $conf->exists($template);

  my $from = $conf->config('invoice_from', $self->agentnum)
    if $conf->exists('invoice_from', $self->agentnum);
  $from = $options{from} if exists($options{from});

  my $to = join(',', $self->invoicing_list_emailonly);
  $to = $options{to} if exists($options{to});
  
  my $subject = "Notice from " . $conf->config('company_name', $self->agentnum)
    if $conf->exists('company_name', $self->agentnum);
  $subject = $options{subject} if exists($options{subject});

  my $notify_template = new Text::Template (TYPE => 'ARRAY',
                                            SOURCE => [ map "$_\n",
                                              $conf->config($template)]
                                           )
    or die "can't create new Text::Template object: Text::Template::ERROR";
  $notify_template->compile()
    or die "can't compile template: Text::Template::ERROR";

  $FS::notify_template::_template::company_name =
    $conf->config('company_name', $self->agentnum);
  $FS::notify_template::_template::company_address =
    join("\n", $conf->config('company_address', $self->agentnum) ). "\n";

  my $paydate = $self->paydate || '2037-12-31';
  $FS::notify_template::_template::first = $self->first;
  $FS::notify_template::_template::last = $self->last;
  $FS::notify_template::_template::company = $self->company;
  $FS::notify_template::_template::payinfo = $self->mask_payinfo;
  my $payby = $self->payby;
  my ($payyear,$paymonth,$payday) = split (/-/,$paydate);
  my $expire_time = timelocal(0,0,0,$payday,--$paymonth,$payyear);

  #credit cards expire at the end of the month/year of their exp date
  if ($payby eq 'CARD' || $payby eq 'DCRD') {
    $FS::notify_template::_template::payby = 'credit card';
    ($paymonth < 11) ? $paymonth++ : ($paymonth=0, $payyear++);
    $expire_time = timelocal(0,0,0,$payday,$paymonth,$payyear);
    $expire_time--;
  }elsif ($payby eq 'COMP') {
    $FS::notify_template::_template::payby = 'complimentary account';
  }else{
    $FS::notify_template::_template::payby = 'current method';
  }
  $FS::notify_template::_template::expdate = $expire_time;

  for (keys %{$options{extra_fields}}){
    no strict "refs";
    ${"FS::notify_template::_template::$_"} = $options{extra_fields}->{$_};
  }

  send_email(from => $from,
             to => $to,
             subject => $subject,
             body => $notify_template->fill_in( PACKAGE =>
                                                'FS::notify_template::_template'                                              ),
            );

}

=item generate_letter CUSTOMER_OBJECT TEMPLATE_NAME OPTIONS

Generates a templated notification to the customer (see L<Text::Template>).

OPTIONS is a hash and may include

I<extra_fields> - a hashref of name/value pairs which will be substituted
   into the template.  These values may override values mentioned below
   and those from the customer record.

The following variables are available in the template instead of or in addition
to the fields of the customer record.

I<$payby> - a description of the method of payment for the customer
            # would be nice to use FS::payby::shortname
I<$payinfo> - the masked account information used to collect for this customer
I<$expdate> - the expiration of the customer payment method in seconds from epoch
I<$returnaddress> - the return address defaults to invoice_latexreturnaddress or company_address

=cut

# a lot like cust_bill::print_latex
sub generate_letter {
  my ($self, $template, %options) = @_;

  return unless $conf->exists($template);

  my $letter_template = new Text::Template
                        ( TYPE       => 'ARRAY',
                          SOURCE     => [ map "$_\n", $conf->config($template)],
                          DELIMITERS => [ '[@--', '--@]' ],
                        )
    or die "can't create new Text::Template object: Text::Template::ERROR";

  $letter_template->compile()
    or die "can't compile template: Text::Template::ERROR";

  my %letter_data = map { $_ => $self->$_ } $self->fields;
  $letter_data{payinfo} = $self->mask_payinfo;

  #my $paydate = $self->paydate || '2037-12-31';
  my $paydate = $self->paydate =~ /^\S+$/ ? $self->paydate : '2037-12-31';

  my $payby = $self->payby;
  my ($payyear,$paymonth,$payday) = split (/-/,$paydate);
  my $expire_time = timelocal(0,0,0,$payday,--$paymonth,$payyear);

  #credit cards expire at the end of the month/year of their exp date
  if ($payby eq 'CARD' || $payby eq 'DCRD') {
    $letter_data{payby} = 'credit card';
    ($paymonth < 11) ? $paymonth++ : ($paymonth=0, $payyear++);
    $expire_time = timelocal(0,0,0,$payday,$paymonth,$payyear);
    $expire_time--;
  }elsif ($payby eq 'COMP') {
    $letter_data{payby} = 'complimentary account';
  }else{
    $letter_data{payby} = 'current method';
  }
  $letter_data{expdate} = $expire_time;

  for (keys %{$options{extra_fields}}){
    $letter_data{$_} = $options{extra_fields}->{$_};
  }

  unless(exists($letter_data{returnaddress})){
    my $retadd = join("\n", $conf->config_orbase( 'invoice_latexreturnaddress',
                                                  $self->agent_template)
                     );
    if ( length($retadd) ) {
      $letter_data{returnaddress} = $retadd;
    } elsif ( grep /\S/, $conf->config('company_address', $self->agentnum) ) {
      $letter_data{returnaddress} =
        join( "\n", map { s/( {2,})/'~' x length($1)/eg;
                          s/$/\\\\\*/;
                          $_;
                        }
                    ( $conf->config('company_name', $self->agentnum),
                      $conf->config('company_address', $self->agentnum),
                    )
        );
    } else {
      $letter_data{returnaddress} = '~';
    }
  }

  $letter_data{conf_dir} = "$FS::UID::conf_dir/conf.$FS::UID::datasrc";

  $letter_data{company_name} = $conf->config('company_name', $self->agentnum);

  my $dir = $FS::UID::conf_dir."/cache.". $FS::UID::datasrc;

  my $lh = new File::Temp( TEMPLATE => 'letter.'. $self->custnum. '.XXXXXXXX',
                           DIR      => $dir,
                           SUFFIX   => '.eps',
                           UNLINK   => 0,
                         ) or die "can't open temp file: $!\n";
  print $lh $conf->config_binary('logo.eps', $self->agentnum)
    or die "can't write temp file: $!\n";
  close $lh;
  $letter_data{'logo_file'} = $lh->filename;

  my $fh = new File::Temp( TEMPLATE => 'letter.'. $self->custnum. '.XXXXXXXX',
                           DIR      => $dir,
                           SUFFIX   => '.tex',
                           UNLINK   => 0,
                         ) or die "can't open temp file: $!\n";

  $letter_template->fill_in( OUTPUT => $fh, HASH => \%letter_data );
  close $fh;
  $fh->filename =~ /^(.*).tex$/ or die "unparsable filename: ". $fh->filename;
  return ($1, $letter_data{'logo_file'});

}

=item print_ps TEMPLATE 

Returns an postscript letter filled in from TEMPLATE, as a scalar.

=cut

sub print_ps {
  my $self = shift;
  my($file, $lfile) = $self->generate_letter(@_);
  my $ps = FS::Misc::generate_ps($file);
  unlink($file.'.tex');
  unlink($lfile);

  $ps;
}

=item print TEMPLATE

Prints the filled in template.

TEMPLATE is the name of a L<Text::Template> to fill in and print.

=cut

sub queueable_print {
  my %opt = @_;

  my $self = qsearchs('cust_main', { 'custnum' => $opt{custnum} } )
    or die "invalid customer number: " . $opt{custvnum};

  my $error = $self->print( $opt{template} );
  die $error if $error;
}

sub print {
  my ($self, $template) = (shift, shift);
  do_print [ $self->print_ps($template) ];
}

#these three subs should just go away once agent stuff is all config overrides

sub agent_template {
  my $self = shift;
  $self->_agent_plandata('agent_templatename');
}

sub agent_invoice_from {
  my $self = shift;
  $self->_agent_plandata('agent_invoice_from');
}

sub _agent_plandata {
  my( $self, $option ) = @_;

  #yuck.  this whole thing needs to be reconciled better with 1.9's idea of
  #agent-specific Conf

  use FS::part_event::Condition;
  
  my $agentnum = $self->agentnum;

  my $regexp = regexp_sql();

  my $part_event_option =
    qsearchs({
      'select'    => 'part_event_option.*',
      'table'     => 'part_event_option',
      'addl_from' => q{
        LEFT JOIN part_event USING ( eventpart )
        LEFT JOIN part_event_option AS peo_agentnum
          ON ( part_event.eventpart = peo_agentnum.eventpart
               AND peo_agentnum.optionname = 'agentnum'
               AND peo_agentnum.optionvalue }. $regexp. q{ '(^|,)}. $agentnum. q{(,|$)'
             )
        LEFT JOIN part_event_condition
          ON ( part_event.eventpart = part_event_condition.eventpart
               AND part_event_condition.conditionname = 'cust_bill_age'
             )
        LEFT JOIN part_event_condition_option
          ON ( part_event_condition.eventconditionnum = part_event_condition_option.eventconditionnum
               AND part_event_condition_option.optionname = 'age'
             )
      },
      #'hashref'   => { 'optionname' => $option },
      #'hashref'   => { 'part_event_option.optionname' => $option },
      'extra_sql' =>
        " WHERE part_event_option.optionname = ". dbh->quote($option).
        " AND action = 'cust_bill_send_agent' ".
        " AND ( disabled IS NULL OR disabled != 'Y' ) ".
        " AND peo_agentnum.optionname = 'agentnum' ".
        " AND ( agentnum IS NULL OR agentnum = $agentnum ) ".
        " ORDER BY
           CASE WHEN part_event_condition_option.optionname IS NULL
           THEN -1
	   ELSE ". FS::part_event::Condition->age2seconds_sql('part_event_condition_option.optionvalue').
        " END
          , part_event.weight".
        " LIMIT 1"
    });
    
  unless ( $part_event_option ) {
    return $self->agent->invoice_template || ''
      if $option eq 'agent_templatename';
    return '';
  }

  $part_event_option->optionvalue;

}

=item queued_bill 'custnum' => CUSTNUM [ , OPTION => VALUE ... ]

Subroutine (not a method), designed to be called from the queue.

Takes a list of options and values.

Pulls up the customer record via the custnum option and calls bill_and_collect.

=cut

sub queued_bill {
  my (%args) = @_; #, ($time, $invoice_time, $check_freq, $resetup) = @_;

  my $cust_main = qsearchs( 'cust_main', { custnum => $args{'custnum'} } );
  warn 'bill_and_collect custnum#'. $cust_main->custnum. "\n";#log custnum w/pid

  $cust_main->bill_and_collect( %args );
}

sub process_bill_and_collect {
  my $job = shift;
  my $param = thaw(decode_base64(shift));
  my $cust_main = qsearchs( 'cust_main', { custnum => $param->{'custnum'} } )
      or die "custnum '$param->{custnum}' not found!\n";
  $param->{'job'}   = $job;
  $param->{'fatal'} = 1; # runs from job queue, will be caught
  $param->{'retry'} = 1;

  $cust_main->bill_and_collect( %$param );
}

sub _upgrade_data { #class method
  my ($class, %opts) = @_;

  my $sql = 'UPDATE h_cust_main SET paycvv = NULL WHERE paycvv IS NOT NULL';
  my $sth = dbh->prepare($sql) or die dbh->errstr;
  $sth->execute or die $sth->errstr;

  local($ignore_expired_card) = 1;
  local($ignore_illegal_zip) = 1;
  local($ignore_illegal_zip) = 1;
  local($ignore_banned_card) = 1;
  $class->_upgrade_otaker(%opts);

}

=back

=head1 BUGS

The delete method.

The delete method should possibly take an FS::cust_main object reference
instead of a scalar customer number.

Bill and collect options should probably be passed as references instead of a
list.

There should probably be a configuration file with a list of allowed credit
card types.

No multiple currency support (probably a larger project than just this module).

payinfo_masked false laziness with cust_pay.pm and cust_refund.pm

Birthdates rely on negative epoch values.

The payby for card/check batches is broken.  With mixed batching, bad
things will happen.

B<collect> I<invoice_time> should be renamed I<time>, like B<bill>.

=head1 SEE ALSO

L<FS::Record>, L<FS::cust_pkg>, L<FS::cust_bill>, L<FS::cust_credit>
L<FS::agent>, L<FS::part_referral>, L<FS::cust_main_county>,
L<FS::cust_main_invoice>, L<FS::UID>, schema.html from the base documentation.

=cut

1;

