/*==============================================================================
  Cohort Visit Tracking & Retention Framework
==============================================================================*/

%macro visit_tracker(
in_ds=, 	/* Long format input file with one row per actual visit (per participant) */
			/* Must include the ID and the date of the visit */
id_var=, 			/* Name of the participant ID variable in in_ds */
visit_date_var=, 	/* Name of the visit date variable */
site_var=, 			/* Name of the site ID varible; leave blank if none */
	
schedule_type=INTERVAL, /* INTERVAL | LOOKUP */
						/* INTERVAL means everyone has the same calendar relative to baseline */
						/* LOOKUP means the visit schedules vary by person */
						
baseline_date_var=, 	/* Name of variable containing date of baseline. Required if schedule_type=INTERVAL */
interval_days=, 		/* Offset days: e.g., 0 30 90 180 365 (space-separated, baseline=0) */

lookup_ds=, 			/* Dataset with per-id target dates */
						/* Required if schedule_type=LOOKUP: (visit_name, target_dt) per id */
						
lookup_id_var=, 			/* Name of the participant ID variable in lookup_ds */
lookup_visit_var=, 			/* e.g., visit_name */
lookup_target_date_var=, 	/* e.g., target_dt */
		
/* Custom ordering for LOOKUP schedules */
order_map_ds=,          /* Dataset with visit_name -> visit_ord mapping */
lookup_order_var=,      /* Numeric order column already present in lookup_ds */
		
window_def=FIXED, 	/* FIXED | SYMMETRIC | LAG */
					/* FIXED: window_start = target - window_pre */
					/* SYMMETRIC: window_end = target + window_post */
					/* LAG: Allows a longer post window. Good if late visits are OK */
window_pre=30, 		/* Days before target allowed */
window_post=30, 	/* Days after target allowed */
late_thresh=7, 		/* Days late threshold (for 'late' flag) */
early_thresh=7, 	/* Days early threshold (for 'early' flag) */
max_gap_days=365, 	/* Define long-term follow-up or gap */

/* Output control */
out_matched=vt_matched, 		/* Expected × (matched actual within window or missing) */
out_unmatched=vt_unmatched, 	/* Actual visits that didn’t land in any window */
out_summary=vt_summary, 		/* Visit-level/site-level completion summary */
out_participant=vt_participant, /* Per-participant counts (on-time/early/late/missed) */
out_pending=vt_pending, 		/* Expected visits due/future as of today() */

make_plots=Y, 	  /* Y/N: Call SGPLOT to show retention curves */
target_rate=,     /* Draw a horizontal reference line (e.g., 0.80 for 80%) */

debug=N		/* Y/N: Keep temp tables */);

/*---------------------------------------------------------------*
| 0) VALIDATE INPUTS:
| Guards against missing required parameters and makes sure
| either the INTERVAL inputs (baseline + intervals) or the
| LOOKUP inputs are provided
 *---------------------------------------------------------------*/
%macro _vt_validate;
	%global vt_abort;
	%let vt_abort=0;

	%if %length(&in_ds)=0 or %length(&id_var)=0 or %length(&visit_date_var)=0 %then
		%do;
			%put ERROR: in_ds, id_var, and visit_date_var are required.;
			%let vt_abort=1;
		%end;

	%if %upcase(&schedule_type)=INTERVAL %then
		%do;

			%if %length(&baseline_date_var)=0 or %length(&interval_days)=0 %then
				%do;
					%put ERROR: For INTERVAL schedule, 
						baseline_date_var and interval_days are required.;
					%let vt_abort=1;
				%end;
		%end;
	%else %if %upcase(&schedule_type)=LOOKUP %then
		%do;

			%if %length(&lookup_ds)=0 or %length(&lookup_id_var)=0 or 
				%length(&lookup_visit_var)=0 or %length(&lookup_target_date_var)=0 %then
					%do;
					%put ERROR: For LOOKUP schedule, lookup_ds, lookup_id_var, 
						lookup_visit_var, lookup_target_date_var are required.;
					%let vt_abort=1;
				%end;
		%end;
%mend _vt_validate;

/*-------------------------------------------------------------------*
| 1) NORMALIZE INPUTS:
| Sorts input visits by id (and site if present) and visit date
*--------------------------------------------------------------------*/
%macro _vt_norm;
	proc sort data=&in_ds out=_vt_visits_sorted;
		by &id_var %sysfunc(coalescec(&site_var, &id_var)) &visit_date_var;
	run;

%mend _vt_norm;

/*----------------------------------*
| 2) BUILD EXPECTED VISIT SCHEDULE
*-----------------------------------*/
%macro _vt_expected;
	%if %upcase(&schedule_type)=INTERVAL %then
		%do;

			/* Parse space-separated interval_days into rows */
			data _vt_intervals;
				length interval_days 8;

				do i=1 by 1 while(scan("&interval_days", i, ' ') ne "");
					interval_days=input(scan("&interval_days", i, ' '), 8.);
					output;
				end;
				drop i;
			run;

			/* One target row per (id x interval) */
			proc sql;
				create table _vt_expected as select v.&id_var
         %if %length(&site_var) %then
					, v.&site_var;
				, i.interval_days as visit_ord   /* ← add */
       , v.&baseline_date_var + i.interval_days as target_dt 
					format=date9.
       , cats("V", put(i.interval_days, best.)) as visit_name length=32 
					from (select distinct &id_var
                      
					%if %length(&site_var) %then
						, &site_var;
				, &baseline_date_var
        from &in_ds) as v cross join _vt_intervals as i;
			quit;

		%end;
	%else
		%do;

			/* LOOKUP: allow custom ordering */
        %local _use_map _use_var;
			%let _use_map=%sysfunc(ifc(%length(&order_map_ds), 1, 0));
			%let _use_var=%sysfunc(ifc(%length(&lookup_order_var), 1, 0));

			/* Expect order_map_ds to have: visit_name (char), visit_ord (num) */
			%if &_use_map %then
				%do;

					proc sql;
						create table _vt_expected as select l.&lookup_id_var         as &id_var
                     %if %length(&site_var) %then
							, coalesce(v.&site_var, .) as &site_var;
						, coalesce(m.visit_ord 
						%if &_use_var %then
							, l.&lookup_order_var;
						, input(compress(l.&lookup_visit_var, , 'kd'), 8.) , 0) as visit_ord
                   , l.&lookup_target_date_var            as 
							target_dt format=date9.
                   , l.&lookup_visit_var                  as 
							visit_name length=32 from &lookup_ds l left join &order_map_ds m on 
							upcase(strip(l.&lookup_visit_var))=upcase(strip(m.visit_name)) left 
							join (select distinct &id_var
                                   
							%if %length(&site_var) %then
								, &site_var;
						from &in_ds) v on l.&lookup_id_var=v.&id_var;
					quit;

				%end;
			%else
				%do;

					/* no map; maybe a var, else digits fallback */
					proc sql;
						create table _vt_expected as select l.&lookup_id_var         as &id_var
                     %if %length(&site_var) %then
							, coalesce(v.&site_var, .) as &site_var;
						, 
						%if &_use_var %then
							l.&lookup_order_var;
						%else
							coalesce(input(compress(l.&lookup_visit_var, , 'kd'), 8.), 0);
						as visit_ord
                   , l.&lookup_target_date_var            as 
							target_dt format=date9.
                   , l.&lookup_visit_var                  as 
							visit_name length=32 from &lookup_ds l left join (select 
							distinct &id_var
                                   
							%if %length(&site_var) %then
								, &site_var;
						from &in_ds) v on l.&lookup_id_var=v.&id_var;
					quit;

				%end;
		%end;
%mend _vt_expected;

/*------------------------------------------------------*
| 3) CREATE WINDOWS:
| Builds the allowable window around each target using
| the window_def policy and the window_pre/window_post
| parameters.
*-------------------------------------------------------*/
%macro _vt_windows;
	data _vt_expected_w;
		set _vt_expected;
		length window_start window_end 8;

		select (upcase("&window_def"));
			when ("FIXED", "SYMMETRIC") 
				do;
					window_start=target_dt - &window_pre;
					window_end=target_dt + &window_post;
				end;
			when ("LAG") 
				do;

					/* Asymmetric post-allowance */
					window_start=target_dt - &window_pre;
					window_end=target_dt + max(&window_post, round(interval_days*0.2));
				end;
			otherwise 
				do;
					window_start=target_dt - &window_pre;
					window_end=target_dt + &window_post;
				end;
		end;
		format window_start window_end date9.;
	run;

%mend _vt_windows;

/*------------------------------------------------------------------*
| 4) GREEDY MATCH:
| Performs a greedy match of actual visits to expected windows:
| - Joins expected windows to actual visits within each window
| - If multiple actuals land in the same window, it keeps the
| first (earliest) per target by default
*-------------------------------------------------------------------*/
%macro _vt_match;
	proc sql;
		create table _vt_all as select e.&id_var
         %if %length(&site_var) %then
			, e.&site_var;
		, e.visit_ord                      /* ← add */
       , e.visit_name
       , e.target_dt
       , e.window_start, e.window_end
       , v.&visit_date_var as actual_dt format=date9.
  from _vt_expected_w e left join _vt_visits_sorted v on 
			e.&id_var=v.&id_var
   
			
				
			%if %length(&site_var) %then
				and e.&site_var=v.&site_var;
		and v.&visit_date_var between e.window_start and e.window_end order 
			by &id_var, target_dt, actual_dt;
	quit;

	/* Outputs one row per expected visit with the chosen actual_dt (or missing if visit not completed) */
	/* Keeps first actual_dt per (id, visit_name) to avoid double-matching */
	data &out_matched;
		set _vt_all(keep=&id_var
         %if %length(&site_var) %then
			&site_var;
		visit_ord visit_name target_dt window_start window_end actual_dt);
		by &id_var target_dt;

		if first.target_dt then
			output;
	run;

	/* Outputs actual visits that were never matched into any window
	(potential unscheduled/protocol deviations, data entry, or off-schedule events) */
	proc sql;
		create table &out_unmatched as select v.* from _vt_visits_sorted v left 
			join &out_matched m on v.&id_var=m.&id_var %if %length(&site_var) %then
				and v.&site_var=m.&site_var;
		and v.&visit_date_var=m.actual_dt where m.&id_var is null;
	quit;

proc datasets lib=work nolist;
  modify &out_unmatched;
  label
    &id_var        = "Participant ID"
    %if %length(&site_var) %then &site_var = "Site ID";
    &visit_date_var= "Actual Visit Date (Unmatched)"
    %if %length(&baseline_date_var) %then &baseline_date_var = "Baseline Date";
  ;
quit;

%mend _vt_match;

/*----------------------------------*
| 5) FLAGS:
| Early/late/missed, gaps, pending
 *-----------------------------------*/
%macro _vt_flags;
	/* Visit-level flags */
	data &out_matched;
		set &out_matched;
		diff_days=actual_dt - target_dt;
		length status $20;

		if not missing(actual_dt) then
			do;

				if diff_days < -&early_thresh then
					status='EARLY';
				else if diff_days > &late_thresh then
					status='LATE';
				else
					status='ON_TIME';
			end;
		else
			status='MISSED';
		label &id_var="Participant ID" 
		%if %length(&site_var) %then
			&site_var="Site ID";
		visit_name="Scheduled Visit" target_dt="Target Date" 
			window_start="Visit Window Start" window_end="Visit Window End" 
			actual_dt="Actual Visit Date" diff_days="Difference (Actual - Target, Days)" 
			status="Visit Status (On-Time/Early/Late/Missed)";
	run;

	/* Participant-level summary */
	proc sql;
		create table &out_participant as select &id_var %if %length(&site_var) %then
			, &site_var;
		, sum(status in ('ON_TIME', 'EARLY', 'LATE')) as n_completed , 
			sum(status='ON_TIME') as n_on_time , sum(status='EARLY') as n_early , 
			sum(status='LATE') as n_late , sum(status='MISSED') as n_missed , calculated 
			n_completed / count(*) as completion_rate format=percent8.1 , max(actual_dt) 
			as last_actual_dt format=date9. from &out_matched group by &id_var 
				
			%if %length(&site_var) %then
				, &site_var;
		;
	quit;

	proc datasets lib=work nolist;
		modify &out_participant;
		label
   			 &id_var="Participant ID" 
		%if %length(&site_var) %then
			&site_var="Site ID";
		n_completed="Completed Visits" n_on_time="On-Time Visits" 
			n_early="Early Visits" n_late="Late Visits" n_missed="Missed Visits" 
			completion_rate="Completion Rate (%)" 
			last_actual_dt="Most Recent Visit Date";
	quit;

	/* Pending/overdue as of today() derived from expected windows */
	data &out_pending;
		set _vt_expected_w;
		length pending_flag $20;

		if missing(window_end) then
			pending_flag='UNKNOWN';
		else if today() <=window_end then
			pending_flag='DUE_OR_OVERDUE';
		else
			pending_flag='EXPIRED';
		keep &id_var 
		%if %length(&site_var) %then
			&site_var;
		visit_name target_dt window_start window_end pending_flag;
		format target_dt window_start window_end date9.;
	run;

	proc datasets lib=work nolist;
		modify &out_pending;
		label
    		&id_var="Participant ID" 
		%if %length(&site_var) %then
			&site_var="Site ID";
		visit_name="Scheduled Visit" target_dt="Target Date" 
			window_start="Window Start" window_end="Window End" 
			pending_flag="Visit Pending/Expired Status";
	quit;

	/* Study/site-level summary by visit_name */
	proc sql;
		create table &out_summary as select visit_ord
    		, visit_name %if %length(&site_var) %then
			, &site_var;
			, sum(status='ON_TIME') as on_time
    		, sum(status='EARLY') as early
    		, sum(status='LATE') as late
    		, sum(status='MISSED') as missed
    		, count(*) as total
    		, (sum(status ne 'MISSED')/calculated total) as completion_rate 
			format=percent8.1 from &out_matched
  		group by visit_ord, visit_name 
			%if %length(&site_var) %then
				, &site_var;
		order by visit_ord 
			%if %length(&site_var) %then
				, &site_var;
				, visit_name;
	quit;

	proc datasets lib=work nolist;
		modify &out_summary;
		label visit_name="Scheduled Visit" 
		%if %length(&site_var) %then
			&site_var="Site ID";
		on_time="On-Time" early="Early" late="Late" missed="Missed" 
			total="Total Expected" completion_rate="Completion Rate (%)" 
			visit_ord="Visit Order (days from Baseline)";
	quit;

%mend _vt_flags;	

/*----------------------------------*
| 6) PLOTS
*-----------------------------------*/
%macro _vt_plots;
	%if %upcase(&make_plots)=Y %then %do;
		ods graphics on;

		proc sgplot data=&out_summary;
			vbar visit_name / response=completion_rate datalabel;
			yaxis grid label="Completion Rate" values=(0 to 1 by 0.1) valuesformat=percent8.0;
			xaxis discreteorder=data label="Visit";
			title1 "Completion Rate by Visit";
			title2 "%sysfunc(today(), worddate.)";

			/* Add reference line if set a target_rate */
			%if %length(&target_rate) %then %do;
				refline &target_rate / axis=y lineattrs=(pattern=shortdash color=red)
					label="Target %sysfunc(putn(&target_rate, percent8.0))";
			%end;
		run;

		ods graphics off;
	%end;
%mend _vt_plots;


/*----------------------------------*
| 6) OPERATORS
*-----------------------------------*/
%_vt_validate;
	%if &vt_abort %then
		%goto _abort;
%_vt_norm;
%_vt_expected;
%_vt_windows;
%_vt_match;
%_vt_flags;
%_vt_plots;
	%goto _done;
%_abort:
	%put ERROR: visit_tracker aborted due to invalid parameters.;
%_done:
%mend visit_tracker;