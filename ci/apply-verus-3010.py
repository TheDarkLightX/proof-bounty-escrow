from pathlib import Path

def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}")
    p.write_text(s.replace(old, new, 1))

replace_once(
    "source/vir/src/prelude.rs",
    "        (declare-fun [mk_fun] (Fun) Fun)\n",
    "        (declare-fun [mk_fun] ([typ] Fun) Fun)\n",
)

replace_once(
    "source/vir/src/prelude.rs",
    """        (axiom (forall ((x Fun)) (!
            (= ([mk_fun] x) x)
            :pattern (([mk_fun] x))
            :qid prelude_mk_fun
            :skolemid skolem_prelude_mk_fun
        )))
""",
    "",
)

replace_once(
    "source/vir/src/sst_to_air.rs",
    """                let lambda = air::ast_util::mk_lambda(&binders, &triggers, qid, &expr);
                str_apply(crate::def::MK_FUN, &vec![lambda])
""",
    """                let lambda = air::ast_util::mk_lambda(&binders, &triggers, qid, &expr);
                let typ = typ_to_id(ctx, &exp.typ);
                str_apply(crate::def::MK_FUN, &vec![typ, lambda])
""",
)

replace_once(
    "source/vir/src/datatype_to_air.rs",
    "        let app = Arc::new(ExprX::ApplyFun(apolytyp.clone(), x_var.clone(), args));\n",
    "        let app = Arc::new(ExprX::ApplyFun(apolytyp.clone(), x_var.clone(), args.clone()));\n",
)

replace_once(
    "source/vir/src/datatype_to_air.rs",
    """        let mk_fun = str_apply(crate::def::MK_FUN, &vec![x_var.clone()]);
        let box_mk_fun = ident_apply(&ctx.name_ctxt.prefix_box(dpath), &vec![mk_fun]);
""",
    """        let mk_fun = str_apply(crate::def::MK_FUN, &vec![id.clone(), x_var.clone()]);
        let box_mk_fun = ident_apply(&ctx.name_ctxt.prefix_box(dpath), &vec![mk_fun.clone()]);
""",
)

marker = """        axiom_commands.push(Arc::new(CommandX::Global(axiom)));

        // SpecFn apply axiom:
"""
insert = """        axiom_commands.push(Arc::new(CommandX::Global(axiom)));

        // A SpecFn is represented by a type-tagged wrapper around the raw AIR function.
        // The wrapper agrees with the raw function on arguments in its declared domain,
        // but is intentionally unconstrained outside that domain. This prevents
        // extensional equality at one SpecFn type from constraining a function at a
        // different SpecFn type.
        let mk_fun_app =
            Arc::new(ExprX::ApplyFun(apolytyp.clone(), mk_fun.clone(), args.clone()));
        let mut mk_fun_params = params.clone();
        mk_fun_params.push(x_param(&datatyp));
        let trigs = vec![mk_fun_app.clone()];
        let name = format!("{}_mk_fun_apply", path_as_friendly_rust_name(dpath));
        let bind = func_bind_trig(
            ctx,
            name,
            tparams,
            &Arc::new(mk_fun_params),
            &trigs,
            None,
        );
        let imply = mk_implies(&inner_pre, &mk_eq(&mk_fun_app, &app));
        let forall = mk_bind_expr(&bind, &imply);
        axiom_commands.push(Arc::new(CommandX::Global(mk_unnamed_axiom(forall))));

        // SpecFn apply axiom:
"""
replace_once("source/vir/src/datatype_to_air.rs", marker, insert)

test_marker = """test_verify_one_file! {
    #[test] return_in_closure verus_code! {
"""
tests = """test_verify_one_file! {
    #[test] issue_3010_same_type_extensionality verus_code! {
        proof fn same_type_extensionality() {
            let f = |x: nat| true;
            let g = |x: nat| x >= 0;
            assert(f =~= g);
            assert(f == g);
        }
    } => Ok(())
}

test_verify_one_file! {
    #[test] issue_3010_lambda_parameter_type_does_not_leak verus_code! {
        proof fn lambda_parameter_type_does_not_leak() {
            assert((|x: nat| true) =~= (|x: nat| x >= 0));
            assert((|x: int| x >= 0)(-1int)); // FAILS
        }
    } => Err(err) => assert_one_fails(err)
}

test_verify_one_file! {
    #[test] issue_3010_quantified_function_type_does_not_leak verus_code! {
        proof fn quantified_function_type_does_not_leak() {
            let f = |x: int| x >= 0;
            let g = |x: int| true;

            assert forall|p: spec_fn(nat) -> bool, q: spec_fn(nat) -> bool|
                #![trigger p(0nat), q(0nat)]
                (forall|x: nat| #[trigger] p(x) == q(x)) implies p == q by {
                assert(p =~= q);
            }

            assert(f(0int) && g(0int));
            assert(f == g); // FAILS
        }
    } => Err(err) => assert_one_fails(err)
}

test_verify_one_file! {
    #[test] return_in_closure verus_code! {
"""
replace_once("source/rust_verify_test/tests/closures.rs", test_marker, tests)
