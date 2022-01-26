










# using SpineInterface
using JuMP
using Cbc
using DataFrames
using Dates
using XLSX

#include("structures.jl")
#include("import_input_data.jl")
include("structures.jl")
#include("import_input_data_new.jl")

function main(imported_data)
    # Basic settings
    model = JuMP.Model(Cbc.Optimizer)
    set_optimizer_attributes(model, "LogLevel" => 1, "PrimalTolerance" => 1e-7)
    export_to_excel = 0

    #if i_data != 0
    #    imported_data = i_data
    #else
    #    imported_data = include("C:\\Users\\dsdennis\\HOPE\\Predicer\\src\\import_input_data.jl")()
    #end
    temporals = sort(imported_data[1])
    scen_p = imported_data[2]
    scenarios = collect(keys(imported_data[2]))
    nodes = imported_data[3]
    processes = imported_data[4]
    markets = imported_data[5]


    println("Importing data...")

    # Add all constraints, (expressions? and variables?) into a large dictionary for easier access, and being able to use the anonymous notation
    # while still being conveniently accessible.
    model_contents = Dict()
    model_contents["c"] = Dict() # constraints
    model_contents["e"] = Dict() # expressions?
    model_contents["v"] = Dict() # variables?

    # Example: node balance_eq
    model_contents["c"]["node_balance_eq"] = Dict()
    model_contents["c"]["node_balance_eq"][("This", "is", "an", "index", "tuple")] = "@constraint(model, variable_at_index == 42)"

    # reserve directions
    res_dir = ["res_up", "res_down"]

    # Get nodes present in reserve markets
    #--------------------------------------------------------------------------------
    res_nodes = []
    res_tuple = []
    for m in keys(markets)
        if markets[m].type == "reserve"
            push!(res_nodes, markets[m].node)
            if markets[m].direction == "up"
                for s in scenarios
                    for t in temporals
                        push!(res_tuple, (m, markets[m].node, res_dir[1], s, t))
                    end
                end
            elseif markets[m].direction == "down"
                for s in scenarios
                    for t in temporals
                        push!(res_tuple, (m, markets[m].node, res_dir[2], s, t))
                    end
                end
            else
                for s in scenarios
                    for t in temporals
                        push!(res_tuple, (m, markets[m].node, res_dir[1], s, t))
                        push!(res_tuple, (m, markets[m].node, res_dir[2], s, t))
                    end
                end
            end
        end
    end
    unique!(res_nodes)

    # Get tuples for process topology (process_tuple) and separate reserve processes and online processes
    #--------------------------------------------------------------------------------
    process_tuple = []
    res_potential_tuple = []
    proc_online_tuple = []
    # mapping flow directions of processes
    for p in keys(processes), s in scenarios, t in temporals
        for topo in processes[p].topos
            push!(process_tuple, (p, topo.source, topo.sink, s, t))
            if (topo.source in res_nodes || topo.sink in res_nodes) && processes[p].is_res
                for r in res_dir
                    push!(res_potential_tuple, (r, p, topo.source, topo.sink, s, t))
                end
            end
        end
        if processes[p].is_online
            push!(proc_online_tuple, (p, s, t))
        end
    end

    # divide reserve_tuple into consumers and producers
    res_pot_prod_tuple = filter(x -> x[4] in res_nodes, res_potential_tuple)
    res_pot_cons_tuple = filter(x -> x[3] in res_nodes, res_potential_tuple)

    # create variables with process_tuple
    @variable(model, v_flow[tup in process_tuple] >= 0)

    # if online variables exist, they are created
    if !isempty(proc_online_tuple)
        @variable(model, v_online[tup in proc_online_tuple], Bin)
        @variable(model, v_start[tup in proc_online_tuple], Bin)
        @variable(model, v_stop[tup in proc_online_tuple], Bin)
    end

    # same for reserve variables (process potential and aggregated)
    if !isempty(res_potential_tuple)
        @variable(model, v_reserve[tup in res_potential_tuple] >= 0)
    end
    if !isempty(res_tuple)
        @variable(model, v_res[tup in res_tuple] >= 0)
    end

    # Tuples for states and balances
    #--------------------------------------------------------------------------------
    nod_tuple = []
    node_balance_tuple = []
    for n in keys(nodes), s in scenarios, t in temporals
        if nodes[n].is_state
            push!(nod_tuple, (n, s, t))
        end
        if !(nodes[n].is_commodity) & !(nodes[n].is_market)
            push!(node_balance_tuple, (n, s, t))
        end
    end
    # Node state variable
    @variable(model, v_state[tup in nod_tuple] >= 0)

    # Dummy variables for node_states
    @variable(model, vq_state_up[tup in node_balance_tuple] >= 0)
    @variable(model, vq_state_dw[tup in node_balance_tuple] >= 0)

    # Balance constraints
    #--------------------------------------------------------------------------------
    e_prod = []
    e_cons = []
    e_state = []
    node_state_tuple = []
    for (i, tu) in enumerate(node_balance_tuple)
        cons = filter(x -> (x[2] == tu[1] && x[4] == tu[2] && x[5] == tu[3]), process_tuple)
        prod = filter(x -> (x[3] == tu[1] && x[4] == tu[2] && x[5] == tu[3]), process_tuple)
        # Get reserve markets for realisation
        real_up = []
        real_dw = []
        resu = filter(x-> x[2] == tu[1] && x[3] == res_dir[1] && x[4] == tu[2] && x[5] == tu[3],res_tuple)
        for j in resu
            push!(real_up,markets[j[1]].realisation)
        end
        resd = filter(x-> x[2] == tu[1] && x[3] == res_dir[2] && x[4] == tu[2] && x[5] == tu[3],res_tuple)
        for j in resd
            push!(real_dw,markets[j[1]].realisation)
        end
        # Check inflow for node
        if nodes[tu[1]].is_inflow
            inflow_val = filter(x->x[1] == tu[3], filter(x->x.scenario == tu[2],nodes[tu[1]].inflow)[1].series)[1][2]
        else
            inflow_val = 0.0
        end

        if isempty(cons)
            if isempty(resd)
                cons_expr = @expression(model, -vq_state_dw[tu] + inflow_val)
            else
                cons_expr = @expression(model, -vq_state_dw[tu] + inflow_val - sum(real_dw .* v_res[resd]))
            end
        else
            if isempty(resd)
                cons_expr = @expression(model, -sum(v_flow[cons]) - vq_state_dw[tu] + inflow_val)
            else
                cons_expr = @expression(model, -sum(v_flow[cons]) - vq_state_dw[tu] + inflow_val - sum(real_dw .* v_res[resd]))
            end
        end
        if isempty(prod)
            if isempty(resu)
                prod_expr = @expression(model, vq_state_up[tu])
            else
                prod_expr = @expression(model, vq_state_up[tu] + sum(real_up .* v_res[resu]))
            end
        else
            if isempty(resu)
                prod_expr = @expression(model, sum(v_flow[prod]) + vq_state_up[tu])
            else
                prod_expr = @expression(model, sum(v_flow[prod]) + vq_state_up[tu] + sum(real_up .* v_res[resu]))
            end
        end

        if nodes[tu[1]].is_state
            if tu[3] == temporals[1]
                state_expr = @expression(model, v_state[tu])
            else
                state_expr = @expression(model, v_state[tu] - v_state[node_balance_tuple[i-1]])
            end
            push!(node_state_tuple, tu)
        else
            state_expr = 0
        end
        push!(e_prod, prod_expr)
        push!(e_cons, cons_expr)
        push!(e_state, state_expr)
    end
    @constraint(model, node_bal_eq[(i, tup) in enumerate(node_balance_tuple)], e_prod[i] + e_cons[i] == e_state[i])
    @constraint(model, node_state_max_up[(i, tup) in enumerate(node_state_tuple)], e_state[i] <= nodes[tup[1]].state.in_max)
    @constraint(model, node_state_max_dw[(i, tup) in enumerate(node_state_tuple)], -e_state[i] <= nodes[tup[1]].state.out_max)
    for tu in node_state_tuple
        set_upper_bound(v_state[tu], nodes[tu[1]].state.state_max)
    end


    # Dynamic equations for start/stop online variables
    #--------------------------------------------------------------------------------
    online_expr = []
    for (i,tup) in enumerate(proc_online_tuple)
        if tup[3] == temporals[1]
            # Note - initial online state is assumed 1!
            dyn_expr = @expression(model,v_start[tup]-v_stop[tup]-v_online[tup]+1)
            push!(online_expr,dyn_expr)
        else
            dyn_expr = @expression(model,v_start[tup]-v_stop[tup]-v_online[tup]+v_online[proc_online_tuple[i-1]])
            push!(online_expr,dyn_expr)
        end
    end

    @constraint(model,online_dyn_eq[(i,tup) in enumerate(proc_online_tuple)],online_expr[i] == 0)

    # Minimum online and offline periods
    for p in keys(processes)
        if processes[p].is_online
            min_online = processes[p].min_online
            min_offline = processes[p].min_offline
            for s in scenarios
                for t in temporals
                    on_hours = filter(x->0<=Dates.value(convert(Dates.Hour,x-t))<=min_online,temporals)
                    off_hours = filter(x->0<=Dates.value(convert(Dates.Hour,x-t))<=min_offline,temporals)
                    @constraint(model,[tup in on_hours],v_online[(p,s,tup)]>=v_start[(p,s,t)])
                    @constraint(model,[tup in off_hours],v_online[(p,s,tup)]<=(1-v_stop[(p,s,t)]))
                end
            end
        end
    end

    # Get tuples for process balance equations (proc_op_balance is for piecewise efficiency curve)
    #--------------------------------------------------------------------------------
    proc_balance_tuple = []
    proc_op_balance_tuple = []
    for p in keys(processes)
        if processes[p].conversion == 1 && !processes[p].is_cf
            if isempty(processes[p].eff_fun)
                for s in scenarios, t in temporals
                    push!(proc_balance_tuple, (p, s, t))
                end
            else
                for s in scenarios, t in temporals, o in processes[p].eff_ops
                    push!(proc_op_balance_tuple, (p, s, t, o))
                end
            end
        end
    end
    @variable(model,v_flow_op_in[tup in proc_op_balance_tuple] >= 0)
    @variable(model,v_flow_op_out[tup in proc_op_balance_tuple] >= 0)
    @variable(model,v_flow_op_bin[tup in proc_op_balance_tuple], Bin)

    # Fixed efficiency case:
    #--------------------------------------------------------------------------------
    nod_eff = []
    for tup in proc_balance_tuple
        # fixed eff value
        if isempty(processes[tup[1]].eff_ts)
            eff = processes[tup[1]].eff
        # timeseries based eff
        else
            eff = filter(x->x[1] == tup[3],filter(x->x.scenario == tup[2],processes[tup[1]].eff_ts)[1].series)[1][2]
        end
        sources = filter(x -> (x[1] == tup[1] && x[3] == tup[1] && x[4] == tup[2] && x[5] == tup[3]), process_tuple)
        sinks = filter(x -> (x[1] == tup[1] && x[2] == tup[1] && x[4] == tup[2] && x[5] == tup[3]), process_tuple)
        push!(nod_eff, sum(v_flow[sinks]) - eff * sum(v_flow[sources]))
    end

    @constraint(model, process_bal_eq[(i, tup) in enumerate(proc_balance_tuple)], nod_eff[i] == 0)

    # Piecewise linear efficiency curve case:
    #--------------------------------------------------------------------------------
    proc_op_tuple = unique(map(x->(x[1],x[2],x[3]),proc_op_balance_tuple))

    op_min = []
    op_max = []
    op_eff = []
    for p in keys(processes)
        if !isempty(processes[p].eff_fun)
            cap = sum(map(x->x.capacity,filter(x->x.source == p,processes[p].topos)))
            for s in scenarios, t in temporals
                for i in 1:length(processes[p].eff_ops)
                    if i==1
                        push!(op_min,0.0)
                    else
                        push!(op_min,processes[p].eff_fun[i-1][1]*cap)
                    end
                    push!(op_max,processes[p].eff_fun[i][1]*cap)
                    push!(op_eff,processes[p].eff_fun[i][2])
                end
            end
        end
    end

    @constraint(model,flow_op_osum[tup in proc_op_tuple],sum(v_flow_op_out[filter(x->x[1:3]==tup,proc_op_balance_tuple)]) == sum(v_flow[filter(x->x[2]==tup[1] && x[4] == tup[2] && x[5] == tup[3],process_tuple)]))
    @constraint(model,flow_op_isum[tup in proc_op_tuple],sum(v_flow_op_in[filter(x->x[1:3]==tup,proc_op_balance_tuple)]) == sum(v_flow[filter(x->x[3]==tup[1] && x[4] == tup[2] && x[5] == tup[3],process_tuple)]))

    @constraint(model,flow_op_lo[(i,tup) in enumerate(proc_op_balance_tuple)], v_flow_op_out[tup] >= v_flow_op_bin[tup] .* op_min[i])
    @constraint(model,flow_op_up[(i,tup) in enumerate(proc_op_balance_tuple)], v_flow_op_out[tup] <= v_flow_op_bin[tup] .* op_max[i])
    @constraint(model,flow_op_ef[(i,tup) in enumerate(proc_op_balance_tuple)], v_flow_op_out[tup] == op_eff[i] .* v_flow_op_in[tup])
    @constraint(model,flow_bin[tup in proc_op_tuple], sum(v_flow_op_bin[filter(x->x[1:3] == tup, proc_op_balance_tuple)]) == 1)

    # CF based processes:
    #--------------------------------------------------------------------------------
    cf_balance_tuple = []
    for p in keys(processes)
        if processes[p].is_cf
            push!(cf_balance_tuple, filter(x -> (x[1] == p), process_tuple)...)
        end
    end

    cf_fac = []
    for tup in cf_balance_tuple
        cf_val = filter(x->x[1] ==  tup[5], filter(x->x.scenario == tup[4],processes[tup[1]].cf)[1].series)[1][2]
        cap = filter(x -> (x.sink == tup[3]), processes[tup[1]].topos)[1].capacity
        push!(cf_fac, sum(v_flow[tup]) - cf_val * cap)
    end

    @constraint(model, cf_bal_eq[(i, tup) in enumerate(cf_balance_tuple)], cf_fac[i] == 0)

    # Limits for Transfer processes
    #--------------------------------------------------------------------------------
    lim_tuple = []
    trans_tuple = []
    for p in keys(processes)
        if !processes[p].is_cf && (processes[p].conversion == 1)
            push!(lim_tuple, filter(x -> x[1] == p && (x[2] == p || x[2] in res_nodes), process_tuple)...)
        elseif processes[p].conversion == 2
            push!(trans_tuple, filter(x -> x[1] == p, process_tuple)...)
        end
    end

    for tup in trans_tuple
        set_upper_bound(v_flow[tup], filter(x -> x.sink == tup[3], processes[tup[1]].topos)[1].capacity)
    end

    # Max/min constraints for processes considering reserves and online variables
    #--------------------------------------------------------------------------------

    p_online = filter(x -> processes[x[1]].is_online, lim_tuple)
    p_offline = filter(x -> !(processes[x[1]].is_online), lim_tuple)
    p_reserve_cons = filter(x -> ("res_up", x...) in res_pot_cons_tuple, lim_tuple)
    p_reserve_prod = filter(x -> ("res_up", x...) in res_pot_prod_tuple, lim_tuple)
    p_noreserve = filter(x -> !(x in p_reserve_cons) && !(x in p_reserve_cons), lim_tuple)
    p_all = filter(x -> x in p_online || x in p_reserve_cons || x in p_reserve_prod, lim_tuple)

    # Base expressions as Dict:
    e_lim_max = Dict(tup => AffExpr(0.0) for tup in lim_tuple)
    e_lim_min = Dict(tup => AffExpr(0.0) for tup in lim_tuple)

    for tup in p_reserve_prod
        add_to_expression!(e_lim_max[tup], v_reserve[("res_up", tup...)])
        add_to_expression!(e_lim_min[tup], -v_reserve[("res_down", tup...)])
    end

    for tup in p_reserve_cons
        add_to_expression!(e_lim_max[tup], v_reserve[("res_down", tup...)])
        add_to_expression!(e_lim_min[tup], -v_reserve[("res_up", tup...)])
    end

    for tup in p_online
        cap = filter(x->x.sink == tup[3] || x.source == tup[2], processes[tup[1]].topos)[1].capacity
        add_to_expression!(e_lim_max[tup], -processes[tup[1]].load_max * cap * v_online[(tup[1], tup[4], tup[5])])
        add_to_expression!(e_lim_min[tup], -processes[tup[1]].load_min * cap * v_online[(tup[1], tup[4], tup[5])])
    end

    for tup in p_offline
        cap = filter(x->x.sink == tup[3] || x.source == tup[2], processes[tup[1]].topos)[1].capacity
        if tup in p_reserve_prod || tup in p_reserve_cons
            add_to_expression!(e_lim_max[tup], -cap)
        else
            set_upper_bound(v_flow[tup], cap)
        end
    end

    con_max_tuples = filter(x -> !(e_lim_max[x] == AffExpr(0)), keys(e_lim_max))
    con_min_tuples = filter(x -> !(e_lim_min[x] == AffExpr(0)), keys(e_lim_min))

    @constraint(model, max_eq[tup in con_max_tuples], v_flow[tup] + e_lim_max[tup] <= 0)
    @constraint(model, min_eq[tup in con_min_tuples], v_flow[tup] + e_lim_min[tup] >= 0)

    # Reserve balances (from reserve potential to reserve product):
    #--------------------------------------------------------------------------------
    e_res_bal_up = []
    e_res_bal_dn = []
    res_eq_tuple = []
    res_eq_updn_tuple = []
    for n in res_nodes, s in scenarios, t in temporals
        res_pot_u = filter(x -> x[1] == res_dir[1] && x[5] == s && x[6] == t && (x[3] == n || x[4] == n), res_potential_tuple)
        res_pot_d = filter(x -> x[1] == res_dir[2] && x[5] == s && x[6] == t && (x[3] == n || x[4] == n), res_potential_tuple)

        res_u = filter(x -> x[3] == res_dir[1] && x[4] == s && x[5] == t && x[2] == n, res_tuple)
        res_d = filter(x -> x[3] == res_dir[2] && x[4] == s && x[5] == t && x[2] == n, res_tuple)

        if !isempty(res_pot_u)
            up_lhs = @expression(model, sum(v_reserve[res_pot_u]))
        else
            up_lhs = @expression(model, 0)
        end
        if !isempty(res_pot_d)
            dn_lhs = @expression(model, sum(v_reserve[res_pot_d]))
        else
            dn_lhs = 0
        end

        if !isempty(res_u)
            up_rhs = @expression(model, sum(v_res[res_u]))
        else
            up_rhs = @expression(model, 0)
        end
        if !isempty(res_d)
            dn_rhs = @expression(model, sum(v_res[res_d]))
        else
            dn_rhs = @expression(model, 0)
        end
        push!(e_res_bal_up, up_lhs - up_rhs)
        push!(e_res_bal_dn, dn_lhs - dn_rhs)
        push!(res_eq_tuple, (n, s, t))
    end

    for m in keys(markets), s in scenarios, t in temporals
        if markets[m].direction == "up_down"
            push!(res_eq_updn_tuple, (m, s, t))
        end
    end

    @constraint(model, res_eq_updn[tup in res_eq_updn_tuple], v_res[(tup[1], markets[tup[1]].node, res_dir[1], tup[2], tup[3])] - v_res[(tup[1], markets[tup[1]].node, res_dir[2], tup[2], tup[3])] == 0)
    @constraint(model, res_eq_up[(i, tup) in enumerate(res_eq_tuple)], e_res_bal_up[i] == 0)
    @constraint(model, res_eq_dn[(i, tup) in enumerate(res_eq_tuple)], e_res_bal_dn[i] == 0)

    # Final reserve product
    res_final_tuple = []
    for m in keys(markets)
        if markets[m].type == "reserve"
            for s in scenarios
                for t in temporals
                    push!(res_final_tuple, (m, s, t))
                end
            end
        end
    end

    @variable(model, v_res_final[tup in res_final_tuple] >= 0)
    
    model_contents["c"]["reserve_final_eq"] = Dict()
    #reserve_market_profits = []
    for tup in res_final_tuple
        r_tup = filter(x -> x[1] == tup[1] && x[4] == tup[2] && x[5] == tup[3], res_tuple)
        model_contents["c"]["reserve_final_eq"][tup] = @constraint(model, sum(v_res[r_tup]) .* (tup[1] == "fcr_n" ? 0.5 : 1.0) .== v_res_final[tup])
        #price = filter(x->x[1] == tup[3],filter(x->x.scenario == tup[2], markets[tup[1]].price)[1].series)[1][2]
        #push!(reserve_market_profits, @expression(model, v_res_final[tup] .* price * scen_p[tup[2]]))
    end

    # Cost calculations:
    # --------------------------------------------------------------------------------
    cost_tup = Dict()
    cost_vec = Dict()
    market_tup = Dict()
    market_vec = Dict()

    commodity_costs = Dict()
    market_costs = Dict()

    for s in scenarios
        cost_tup[s] = []
        cost_vec[s] = []
        market_tup[s] = []
        market_vec[s] = []
        for n in keys(nodes)
            #Commodity costs:
            if nodes[n].is_commodity
                push!(cost_tup[s], filter(x -> x[2] == n && x[4] == s, process_tuple)...)
                push!(cost_vec[s], map(x -> x[2], filter(x->x.scenario == s,nodes[n].cost)[1].series)...)
            end
            # Spot-Market costs and profits
            if nodes[n].is_market
                push!(market_tup[s], filter(x -> x[2] == n && x[4] == s, process_tuple)...)
                push!(market_tup[s], filter(x -> x[3] == n && x[4] == s, process_tuple)...)
                price = map(x -> x[2], filter(x->x.scenario == s,markets[n].price)[1].series)
                push!(market_vec[s], price...)
                push!(market_vec[s], -price...)
            end
        end
        if !isempty(cost_tup[s])
            commodity_costs[s] = @expression(model,cost_vec[s].*v_flow[cost_tup[s]])
        end
        if !isempty(market_tup[s])
            market_costs[s] = @expression(model,market_vec[s].*v_flow[market_tup[s]])
        end
    end

    # VOM costs:
    vom_tup = Dict()
    vom_vec = Dict()
    vom_costs = Dict()
    for s in scenarios
        vom_tup[s] = []
        vom_vec[s] = []
    end

    for tup in unique(map(x->(x[1],x[2],x[3]),process_tuple))
        vom = filter(x->x.source == tup[2] && x.sink == tup[3], processes[tup[1]].topos)[1].VOM_cost
        if !(vom == 0)
            for s in scenarios
                push!(vom_tup[s],filter(x->x[1:3] == tup && x[4] == s, process_tuple)...)
                push!(vom_vec[s],vom*ones(length(temporals))...)
            end
        end
    end

    for s in scenarios
        if !isempty(vom_tup[s])
            vom_costs[s] = @expression(model,vom_vec[s].*v_flow[vom_tup[s]])
        end 
    end

    # Start costs:
    start_costs = Dict()
    for s in scenarios
        start_tuple = filter(x->x[2]==s,proc_online_tuple)
        start_costs[s] = []
        if !isempty(start_tuple)
            for tup in start_tuple
                push!(start_costs[s],@expression(model,processes[tup[1]].start_cost*v_start[tup]))
            end
        end
    end
    
    # Reserve profits:
    reserve_costs = Dict()
    for s in scenarios
        reserve_costs[s] = []
    end

    for tup in res_final_tuple
        price = filter(x->x[1] == tup[3],filter(x->x.scenario == tup[2], markets[tup[1]].price)[1].series)[1][2]
        push!(reserve_costs[tup[2]],-price*v_res_final[tup])
    end
    
    total_costs = Dict()
    for s in scenarios
        total_costs[s] = sum(commodity_costs[s])+sum(market_costs[s])+sum(vom_costs[s])+sum(reserve_costs[s])+sum(start_costs[s])
    end
    

    #=
    cost_tup = []
    cost_vec = []
    market_tup = []
    market_vec = []
    
    for n in keys(nodes)
        # Commodity costs
        if nodes[n].is_commodity
            push!(cost_tup, filter(x -> x[2] == n, process_tuple)...)
            for s in scenarios
                push!(cost_vec, scen_p[s]*map(x -> x[2], filter(x->x.scenario == s,nodes[n].cost)[1].series)...)
            end
        end
        # Market costs/profits
        if nodes[n].is_market
            for s in scenarios
                push!(market_tup, filter(x -> x[2] == n && x[4] == s, process_tuple)...)
                push!(market_tup, filter(x -> x[3] == n && x[4] == s, process_tuple)...)
                price = map(x -> x[2], filter(x->x.scenario == s,markets[n].price)[1].series)*scen_p[s]
                push!(market_vec, price...)
                push!(market_vec, -price...)
            end
        end
    end
    if !isempty(cost_tup)
        @expression(model, commodity_costs, v_flow[cost_tup] .* cost_vec)
    end
    if !isempty(market_tup)
        @expression(model, market_costs, v_flow[market_tup] .* market_vec)
    end
    

    # VOM costs:
    vom_tup = []
    vom_vec = []
    for tup in unique(map(x->(x[1],x[2],x[3]),process_tuple))
        vom = filter(x->x.source == tup[2] && x.sink == tup[3], processes[tup[1]].topos)[1].VOM_cost
        if !(vom == 0)
            for s in scenarios
                push!(vom_tup,filter(x->x[1:3] == tup && x[4] == s, process_tuple)...)
                push!(vom_vec,scen_p[s]*vom*ones(length(temporals))...)
            end
        end
    end

    if !isempty(vom_tup)
        @expression(model,vom_costs, vom_vec.*v_flow[vom_tup])
    end
    
    # Start costs!!!:
    @expression(model,start_cost_expr[tup in proc_online_tuple], processes[tup[1]].start_cost*v_start[tup])
    =#

    #reserve_market_costs = -1 * sum(reserve_market_profits)

    # Fixed values for markets (energy/reserve):
    #----------------------------------------------------------------------------------------------
    fix_expr = []
    for m in keys(markets)
        if !isempty(markets[m].fixed)
            temps = map(x->x[1],markets[m].fixed)
            fix_vec = map(x->x[2],markets[m].fixed)

            if markets[m].type == "energy"
                for (i,t) in enumerate(temps)
                    for s in scenarios
                        tup1 = filter(x->x[2]==m && x[4]==s && x[5]==t,process_tuple)[1]
                        tup2 = filter(x->x[3]==m && x[4]==s && x[5]==t,process_tuple)[1]
                        push!(fix_expr,@expression(model,v_flow[tup1]-v_flow[tup2]-fix_vec[i]))
                    end
                end
            elseif markets[m].type == "reserve"
                for (i,t) in enumerate(temps)
                    for s in scenarios
                        fix(v_res_final[(m,s,t)],fix_vec[i]; force=true)
                    end
                end
            end
        end
    end
    @constraint(model,ene_fix[i in 1:length(fix_expr)], fix_expr[i] == 0)

    # Constraints for bidding price and volume scenarios P(s1)>P(s2) => V(s1)>V(s2):
    #---------------------------------------------------------------------------------------------
    price_matr = Dict()
    for m in keys(markets)
        for (i,s) in enumerate(scenarios)
            vec = map(x->x[2],filter(x->x.scenario == s, markets[m].price)[1].series)
            if i == 1
                price_matr[m] = vec
            else
                price_matr[m] = hcat(price_matr[m],vec)
            end
        end
    end
    for m in keys(markets)
        for (i,t) in enumerate(temporals)
            s_indx = sortperm((price_matr[m][i,:]))
            if markets[m].type == "energy"
                for k in 2:length(s_indx)
                    if price_matr[m][s_indx[k]] == price_matr[m][s_indx[k-1]]
                        @constraint(model, v_flow[filter(x->x[3]==markets[m].node && x[5]==t && x[4]==scenarios[s_indx[k]],process_tuple)[1]]-v_flow[filter(x->x[2]==markets[m].node && x[5]==t && x[4]==scenarios[s_indx[k]],process_tuple)[1]] == 
                            v_flow[filter(x->x[3]==markets[m].node && x[5]==t && x[4]==scenarios[s_indx[k-1]],process_tuple)[1]]-v_flow[filter(x->x[2]==markets[m].node && x[5]==t && x[4]==scenarios[s_indx[k-1]],process_tuple)[1]])
                    else
                        @constraint(model, v_flow[filter(x->x[3]==markets[m].node && x[5]==t && x[4]==scenarios[s_indx[k]],process_tuple)[1]]-v_flow[filter(x->x[2]==markets[m].node && x[5]==t && x[4]==scenarios[s_indx[k]],process_tuple)[1]] >= 
                            v_flow[filter(x->x[3]==markets[m].node && x[5]==t && x[4]==scenarios[s_indx[k-1]],process_tuple)[1]]-v_flow[filter(x->x[2]==markets[m].node && x[5]==t && x[4]==scenarios[s_indx[k-1]],process_tuple)[1]])
                    end
                end
            elseif markets[m].type == "reserve"
                for k in 2:length(s_indx)
                    if price_matr[m][s_indx[k]] == price_matr[m][s_indx[k-1]]
                        @constraint(model, v_res_final[(m,scenarios[s_indx[k]],t)] == v_res_final[(m,scenarios[s_indx[k-1]],t)])
                    else
                        @constraint(model, v_res_final[(m,scenarios[s_indx[k]],t)] >= v_res_final[(m,scenarios[s_indx[k-1]],t)])
                    end

                end
            end
        end
    end
    
    # Ramp constraints
    #= 
    function get_time_index_index(ts, t)
        for i in 1:length(ts)
            if ts[i] == t
                return i
            end
        end
        return 0
    end
                    
    ramp_tuple = []
    e_ramp = []
    for tup in process_tuple
        if processes[tup[1]].conversion == "1" && !processes[tup[1]].is_cf && tup[1] == tup[2]
            cap = filter(x -> x[1]==tup[2] && x[2] == tup[3], processes[tup[1]].topos)[1][3]
            t = get_time_index_index(temporals, tup[4])
            if t == 1
                ramp_expr = 0
            else
                now_tup = (tup[1], tup[2], tup[3], temporals[t])
                then_tup = (tup[1], tup[2], tup[3], temporals[t - 1])
                ramp_expr = @expression(model, (v_flow[now_tup] - v_flow[then_tup]) / cap)
            end
            push!(ramp_tuple, tup)
            push!(e_ramp, ramp_expr)
        end
    end
      
    

    @constraint(model, process_ramp_up_eq[(i, tup) in enumerate(ramp_tuple)], e_ramp[i] <= processes[ramp_tuple[i][1]].ramp_up)
    @constraint(model, process_ramp_dn_eq[(i, tup) in enumerate(ramp_tuple)], -e_ramp[i] <= processes[ramp_tuple[i][1]].ramp_down) 
    =#

    # Objective function (commodity + market + VOM + start costs)
    #----------------------------------------------------------------------------------------------------
    #@objective(model, Min, sum(commodity_costs) + sum(market_costs) + sum(vom_costs) + 100000 * sum(vq_state_dw .+ vq_state_up) + reserve_market_costs + sum(start_cost_expr))
    @objective(model, Min, sum(values(scen_p).*values(total_costs))+ 100000 * sum(vq_state_dw .+ vq_state_up))
    optimize!(model)
    println(raw_status(model))

    # Result Dataframes:
    #---------------------------------------------------------------------------------------------------
    v_flow_df = DataFrame(t = temporals)
    v_state_df = DataFrame(t = temporals)
    v_res_pot_df = DataFrame(t = temporals)
    v_online_df = DataFrame(t = temporals)
    v_res_final_df = DataFrame(t = temporals)
    for tup in unique(map(x->(x[1],x[2],x[3],x[4]),process_tuple))
        colname = join(tup,"-")
        v_flow_df[!, colname] = value.(v_flow[filter(x->x[1:4] == tup, process_tuple)].data)
    end

    #=
    for tup in unique(map(x->(x[1],x[2]),nod_tuple))
        tuple_indices = filter(x -> x[1] == tup[1], nod_tuple)
        colname = string(tup[1])
        v_state_df[!, colname] = map(x -> value.(v_state)[tuple_indices][x], tuple_indices)
    end

    for tup in unique(map(x->(x[1],x[2]),res_potential_tuple))
        tuple_indices = filter(x -> x[1:4] == tup[1:4], res_potential_tuple)
        print(tuple_indices, "\n")
        colname = string(tup[1:4])
        v_res_pot_df[!, colname] = map(x -> value.(v_reserve)[tuple_indices][x], tuple_indices)
    end
    =#
    for tup in unique(map(x->(x[1],x[2]),res_final_tuple))
        colname = join(tup,"-")
        v_res_final_df[!, colname] = value.(v_res_final[filter(x->x[1:2] == tup, res_final_tuple)].data)
    end
    #=
    for tup in filter(t -> t[2] == temporals[1], res_final_tuple)
        tuple_indices = filter(x -> x[1] == tup[1], res_final_tuple)
        colname = string(tup[1])
        v_res_final_df[!, colname] = map(x -> value.(v_res_final)[tuple_indices][x], tuple_indices)
    end
    =#

    for tup in unique(map(x->(x[1],x[2]),proc_online_tuple))
        colname1 = "status-"*join(tup,"-")
        v_online_df[!,colname1] = value.(v_online[filter(x->x[1:2] == tup, proc_online_tuple)].data)
        colname2 = "start-"*join(tup,"-")
        v_online_df[!,colname2] = value.(v_start[filter(x->x[1:2] == tup, proc_online_tuple)].data)
        colname3 = "stop-"*join(tup,"-")
        v_online_df[!,colname3] = value.(v_stop[filter(x->x[1:2] == tup, proc_online_tuple)].data)
    end

    # Result file (timestamped):
    #---------------------------------------------------------------------------------------------------------------
    if export_to_excel == 1
        output_path = ".//results_"*Dates.format(Dates.now(), "yyyy-mm-dd-HH-MM-SS")*".xlsx"
        XLSX.openxlsx(output_path, mode="w") do xf
            sheet = xf[1]
            XLSX.rename!(sheet,"FLOWS")
            XLSX.addsheet!(xf,"RESERVES")
            sheet2 = xf[2]
            XLSX.writetable!(sheet, collect(eachcol(v_flow_df)), names(v_flow_df))
            XLSX.writetable!(sheet2, collect(eachcol(v_res_final_df)), names(v_res_final_df))
        end
    end

    return (model,v_flow_df,v_res_final_df,v_online_df)
    

    #=
    pt1 = @df v_flow_df plot(:t, cols(propertynames(v_flow_df)[2:2]), lw = 2, xticks = Time(0):Hour(4):Time(23))
    pt2 = @df v_flow_df plot(:t, cols(propertynames(v_flow_df)[3:4]), lw = 2, xticks = Time(0):Hour(4):Time(23))
    pt3 = @df v_flow_df plot(:t, cols(propertynames(v_flow_df)[5:7]), lw = 2, xticks = Time(0):Hour(4):Time(23))
    pt4 = @df v_flow_df plot(:t, cols(propertynames(v_flow_df)[8:9]), lw = 2, xticks = Time(0):Hour(4):Time(23))
    pt5 = @df v_flow_df plot(:t, cols(propertynames(v_flow_df)[10:11]), lw = 2, xticks = Time(0):Hour(4):Time(23))
    pt6 = @df v_flow_df plot(:t, cols(propertynames(v_flow_df)[12:12]), lw = 2, xticks = Time(0):Hour(4):Time(23))
    pt7 = @df v_state_df plot(:t, cols(propertynames(v_state_df)[2:end]), lw = 2, xticks = Time(0):Hour(4):Time(23))
    pt8 = @df v_res_final_df plot(:t, cols(propertynames(v_res_final_df)[2:end]), lw = 2, xticks = Time(0):Hour(4):Time(23))
    plot(pt1, pt2, pt3, pt4, pt5, pt6, pt7, pt8, layout = grid(8, 1), size = (1000, 1000), legend = :outerright)
    =#

    # @expression(model, e_cons[tup in node_balance_tuple], reduce(+,v_flow[filter(x->(x[3]==tup[1] && x[4]==tup[2]),process_tuple)],init = 0)-vq_state_up[tup])

    # @constraint(model, node_bal_eq[tup in node_balance_tuple], sum(v_flow[filter(x->(x[2]==tup[1] && x[4]==tup[2]),process_tuple)]) == 0)
    # @constraint(model, node_bal_eq[tup in node_balance_tuple], sum(v_flow[filter(x->(x[3]==tup[1] && x[4]==tup[2]),process_tuple)]) == 0)


    # e_prod = @expression(model, sum(v_flow[tup] for tup in process_tuple if tup[3]==nodes[n].name && tup[4]==t))

    # e_cons = @expression(model, sum(-v_flow[tup] for tup in process_tuple if tup[2]==nodes[n].name && tup[4]==t))



    # @expression(model, nod_test, sum(v_flow[tup] for tup in process_tuple if tup[4]=="t1"))

    # @variable(model, node_state[keys(nodes), stochastics, temporals])

    # @variable(model, v_flow[p in keys(processes), "SOURCE", "SINK", stochastics, temporals])
    # t in processes[p].topos



    # As per Topis contrbution to discussion:
    # @variable(model, node_state[nodes, stochastics, temporals])
    # @variable(model, process_flow[processes, directions, nodes, stochastics, temporals])

    # in case inflow can not be balanced
    # @variable(model, node_slack[nodes, stochastics, temporals])

    # Esas proposal for one (NGCHP) process for example
    # v_flow(process, source node(NG), process(NGCHP), stochastics, temporal)
    # v_flow(process, process(NGCHP), sink node1(dh), stochastics, temporal)
    # v_flow(process, process(NGCHP), sink node2(elec), stochastics, temporal)
    # @variable(model, v_flow[p in processes, p.sources, p.sinks, stochastics, temporals])

    # Connections are basically a simple process with a efficiency of 1 (?). No need to implement?

    # Node balance constraints
    # sum of process flows in and out from a node should be equal


    # process flow balance constraints
    # ensure that the flows from/in to a process (?) are at equilibrium.
    # In that case also need to model exhaust/wast heat/energy as one additional flow
    # OR, just have flow_in * eff = flow_out

    # node_slack constraints. Actually not needed, since the cost could be set as absolute?

    # Get input data into abstract format

    # Into node / process struct format
    # Functions for each type of "special plant", such as CHP or wind, etc
    # This means, that the abstract format data can be converted into a JuMP model easily

    # Translate abstract format into JuMP

    # How to do this?
    # Processes as variables, and nodes as constraints?

    # Run JuMP model

    # Translate results to human-readable format

end

end  # End module