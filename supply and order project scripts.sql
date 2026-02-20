-- Procedure for Supplier Performance
CREATE OR REPLACE PROCEDURE pr_supplier_performance (
    p_from_date IN DATE,
    p_to_date   IN DATE ) IS 
CURSOR c_sup IS
SELECT s.supplier_id, s.first_name, s.last_name
FROM   suppliers s ORDER  BY s.supplier_id;

r_sup c_sup%ROWTYPE;

v_total_orders      NUMBER;
v_late_orders       NUMBER;
v_avg_delay         NUMBER;
v_total_cost        NUMBER;
BEGIN
DBMS_OUTPUT.PUT_LINE('SUPPLIER PERFORMANCE');

OPEN c_sup; 
LOOP
FETCH c_sup INTO r_sup;
EXIT WHEN c_sup%NOTFOUND;

SELECT NVL(COUNT(*), 0), NVL(SUM(total_cost), 0)
INTO   v_total_orders, v_total_cost
FROM   supply_orders so
WHERE  so.supplier_id = r_sup.supplier_id
AND  so.order_date BETWEEN p_from_date AND p_to_date;

SELECT NVL(COUNT(*), 0),
NVL(AVG( (NVL(so2.expected_delivery_date, so2.order_date)) -
(SELECT MIN(sod.delivery_date) FROM supply_order_details sod
WHERE sod.supply_order_id = so2.supply_order_id)), 0)
INTO   v_late_orders, v_avg_delay FROM   supply_orders so2
WHERE  so2.supplier_id = r_sup.supplier_id
AND  so2.order_date BETWEEN p_from_date AND p_to_date
AND  EXISTS (SELECT 1 FROM supply_order_details sod2
WHERE  sod2.supply_order_id = so2.supply_order_id
AND  sod2.delivery_date > so2.expected_delivery_date);

DBMS_OUTPUT.PUT_LINE(
    'Supplier ID=' || r_sup.supplier_id ||
    ' | Name=' || r_sup.first_name || ' ' || r_sup.last_name ||
    ' | Orders=' || v_total_orders ||
    ' | Late=' || v_late_orders ||
    ' | Avg delay=' || ROUND(v_avg_delay, 2) || ' days' ||
    ' | Total cost=' || NVL(v_total_cost, 0)
        );
    END LOOP;
    CLOSE c_sup;
END pr_supplier_performance;
/

--Testing
BEGIN
pr_supplier_performance('11-11-2025', '12-11-2025');
END;


-- Trigger for Updating Inventory Stock
CREATE OR REPLACE TRIGGER trg_inventory_log_update_stock
AFTER INSERT ON inventory_log
FOR EACH ROW
IS v_delta NUMBER := 0;
BEGIN
CASE LOWER(:NEW.change_type)
WHEN 'purchase' THEN v_delta := :NEW.quantity_changed;              
WHEN 'usage' THEN v_delta := - :NEW.quantity_changed;            
WHEN 'waste' THEN v_delta := - :NEW.quantity_changed;          
ELSE v_delta := 0;
END CASE;

IF v_delta <> 0 THEN UPDATE ingredients
SET current_stock = current_stock + v_delta
WHERE  ingredient_id = :NEW.ingredient_id;
END IF;
END;
/


-- Trigger for Log Usage On Order Served old version
CREATE OR REPLACE TRIGGER trg_order_served_usage
AFTER UPDATE OF order_status ON customer_orders
FOR EACH ROW
WHEN (NEW.order_status = 'Ready' AND NVL(OLD.order_status, 'X') <> 'Ready')
IS BEGIN
FOR rec IN (SELECT r.ingredient_id,r.quantity_required,d.quantity
FROM customer_order_details d
JOIN menu_recipes r ON r.menu_item_id = d.menu_item_id
WHERE  d.order_id = :NEW.order_id) LOOP
INSERT INTO inventory_log (log_id, ingredient_id, shift_id, change_date,change_type, quantity_changed) 
VALUES (inventory_log_seq.NEXTVAL, rec.ingredient_id,NULL,SYSDATE,'Usage',rec.quantity_required * rec.quantity);
END LOOP;
END;
/


-- Inventory Log Sequence
CREATE SEQUENCE inventory_log_seq
START WITH 1001
INCREMENT BY 1;

--Trigger for Log Usage On Order Served final version
CREATE OR REPLACE TRIGGER trg_order_served_usage
AFTER UPDATE OF order_status ON customer_orders
FOR EACH ROW
WHEN (NEW.order_status = 'Ready' AND NVL(OLD.order_status, 'X') <> 'Ready')
DECLARE
v_shift_id employee_shifts.shift_id%TYPE;
BEGIN
SELECT MAX(shift_id) INTO   v_shift_id FROM   employee_shifts;
IF v_shift_id IS NULL THEN v_shift_id := 1;
END IF;
FOR rec IN (SELECT r.ingredient_id, r.quantity_required, d.quantity
FROM   customer_order_details d
JOIN menu_recipes r ON r.menu_item_id = d.menu_item_id
WHERE  d.order_id = :NEW.order_id)
LOOP
INSERT INTO inventory_log (log_id,ingredient_id,shift_id,change_date,change_type,quantity_changed)
VALUES (inventory_log_seq.NEXTVAL,rec.ingredient_id,v_shift_id,SYSDATE,'Usage',rec.quantity_required * rec.quantity);
END LOOP;
END;
/


-- Trigger for Log Purchase On Supply Delivered
CREATE OR REPLACE TRIGGER trg_supply_delivered_purchase
AFTER UPDATE OF status ON supply_orders
FOR EACH ROW
WHEN (NEW.status = 'Delivered' AND NVL(OLD.status, 'X') <> 'Delivered')
DECLARE
v_shift_id employee_shifts.shift_id%TYPE;
BEGIN
SELECT MAX(shift_id) INTO   v_shift_id FROM   employee_shifts;
IF v_shift_id IS NULL THEN v_shift_id := 1;
END IF;
FOR rec IN (SELECT d.ingredient_id, d.quantity_ordered
FROM supply_order_details d WHERE  d.supply_order_id = :NEW.supply_order_id)
LOOP
INSERT INTO inventory_log (log_id,ingredient_id,shift_id,change_date,change_type,quantity_changed)
VALUES (inventory_log_seq.NEXTVAL,rec.ingredient_id,v_shift_id, SYSDATE,'Purchase',rec.quantity_ordered);
END LOOP;
END;
/


-- Wastage Log Sequence
CREATE SEQUENCE wastage_log_seq
START WITH 101
INCREMENT BY 1;

-- Trigger for Log Waste On Expiry
CREATE OR REPLACE TRIGGER trg_expiry_to_waste
AFTER UPDATE OF expiry_date ON supply_order_details
FOR EACH ROW
WHEN (NEW.expiry_date < SYSDATE AND (OLD.expiry_date IS NULL OR OLD.expiry_date >= SYSDATE))
DECLARE
v_log_id   inventory_log.log_id%TYPE;
v_shift_id employee_shifts.shift_id%TYPE;
BEGIN
SELECT MAX(shift_id) INTO v_shift_id FROM employee_shifts;

IF v_shift_id IS NULL THEN v_shift_id := 1;
END IF;
INSERT INTO inventory_log (log_id,ingredient_id,shift_id,change_date,change_type,quantity_changed)
VALUES (inventory_log_seq.NEXTVAL,:NEW.ingredient_id,v_shift_id,SYSDATE,'Waste',:NEW.quantity_ordered)
RETURNING log_id INTO v_log_id;

INSERT INTO wastage_log (waste_id,log_id,reason_type)
VALUES (wastage_log_seq.NEXTVAL, v_log_id,'Expiry');
END;
/


-- Function for Menu Item Cost
CREATE OR REPLACE FUNCTION fn_menu_item_cost 
(p_menu_item_id IN menu_items.menu_item_id%TYPE) 
RETURN NUMBER IS
CURSOR c_recipes IS
SELECT mr.ingredient_id,mr.quantity_required,i.unit_price
FROM menu_recipes mr
JOIN ingredients i ON i.ingredient_id = mr.ingredient_id
WHERE mr.menu_item_id = p_menu_item_id;

r_rec c_recipes%ROWTYPE;
v_total_cost NUMBER := 0;
BEGIN
OPEN c_recipes;
LOOP
FETCH c_recipes INTO r_rec;
EXIT WHEN c_recipes%NOTFOUND;

v_total_cost := v_total_cost + (r_rec.quantity_required * r_rec.unit_price);
END LOOP;
CLOSE c_recipes;

RETURN v_total_cost;
EXCEPTION
WHEN NO_DATA_FOUND THEN RETURN 0;
WHEN OTHERS THEN RETURN NULL;
END fn_menu_item_cost;
/


-- Procedure for Menu Profit Report
CREATE OR REPLACE PROCEDURE pr_menu_profit_report (
p_from_date IN DATE,
 p_to_date   IN DATE) IS
CURSOR c_items IS
SELECT mi.menu_item_id,mi.item_name,mi.category
FROM menu_items mi
ORDER BY mi.menu_item_id;
r_item      c_items%ROWTYPE;

v_qty_sold   NUMBER;
v_revenue    NUMBER;
v_unit_cost  NUMBER;
v_total_cost NUMBER;
v_profit     NUMBER;
v_margin     NUMBER;
BEGIN
DBMS_OUTPUT.PUT_LINE('Menu profit report');
DBMS_OUTPUT.PUT_LINE(
        'Period: ' ||
        TO_CHAR(p_from_date, 'YYYY-MM-DD') || ' - ' ||
        TO_CHAR(p_to_date,   'YYYY-MM-DD'));
OPEN c_items;
LOOP
FETCH c_items INTO r_item;
EXIT WHEN c_items%NOTFOUND;

SELECT NVL(SUM(cod.quantity), 0),NVL(SUM(cod.quantity * cod.unit_price), 0)
INTO v_qty_sold, v_revenue
FROM   customer_order_details cod
JOIN customer_orders co ON co.order_id = cod.order_id
WHERE  cod.menu_item_id = r_item.menu_item_id
AND  co.order_status = 'Ready'
AND  co.order_date BETWEEN p_from_date AND p_to_date;

IF v_qty_sold = 0 THEN CONTINUE;
END IF;

v_unit_cost := fn_menu_item_cost(r_item.menu_item_id);

v_total_cost := v_unit_cost * v_qty_sold;
v_profit := v_revenue - v_total_cost;

IF v_revenue > 0 THEN v_margin := v_profit / v_revenue;
ELSE v_margin := NULL;
END IF;

DBMS_OUTPUT.PUT_LINE(
              'Id=' || r_item.menu_item_id
           || ' | ' || r_item.item_name
           || ' | Category=' || r_item.category
           || ' | Sold=' || v_qty_sold
           || ' | Revenue=' || TO_CHAR(ROUND(v_revenue,    2))
           || ' | Cost='    || TO_CHAR(ROUND(v_total_cost, 2))
           || ' | Profit='  || TO_CHAR(ROUND(v_profit,     2))
           || ' | Margin='  || CASE
                                   WHEN v_margin IS NULL THEN 'N/A'
                                   ELSE TO_CHAR(ROUND(v_margin * 100, 2)) || '%'
                               END
        );
END LOOP;
CLOSE c_items;
END pr_menu_profit_report;
/

BEGIN 
pr_menu_profit_report('11/11/2025', '11/12/2025');
END;


-- Procedure for Top Selling Items
CREATE OR REPLACE PROCEDURE pr_top_selling_items (
    p_from_date IN DATE,
    p_to_date   IN DATE,
    p_top_n     IN PLS_INTEGER DEFAULT 10
) IS
CURSOR c_sales IS
SELECT mi.menu_item_id,mi.item_name, mi.category, SUM(cod.quantity) AS total_qty,
SUM(cod.quantity * cod.unit_price) AS total_revenue
FROM menu_items mi
JOIN customer_order_details cod ON cod.menu_item_id = mi.menu_item_id
JOIN customer_orders co ON co.order_id = cod.order_id
WHERE  co.order_status = 'Ready'
AND  co.order_date BETWEEN p_from_date AND p_to_date
GROUP BY mi.menu_item_id, mi.item_name, mi.category
ORDER BY total_revenue DESC;

TYPE t_sales_row IS RECORD (
menu_item_id   menu_items.menu_item_id%TYPE,
item_name      menu_items.item_name%TYPE,
category       menu_items.category%TYPE,
total_qty      NUMBER,
total_revenue  NUMBER);

TYPE t_sales_tab IS TABLE OF t_sales_row;
v_sales t_sales_tab := t_sales_tab();

v_counter PLS_INTEGER := 0;
r_row     t_sales_row;
BEGIN
DBMS_OUTPUT.PUT_LINE('Top selling items');

OPEN c_sales;
LOOP
FETCH c_sales INTO r_row;
EXIT WHEN c_sales%NOTFOUND OR v_counter >= p_top_n;

v_counter := v_counter + 1;

v_sales.EXTEND;
v_sales(v_sales.LAST) := r_row;
END LOOP;
CLOSE c_sales;

FOR i IN 1 .. v_sales.COUNT LOOP
DBMS_OUTPUT.PUT_LINE(
            i || '. ID=' || v_sales(i).menu_item_id ||
            ' | ' || v_sales(i).item_name ||
            ' | Category=' || v_sales(i).category ||
            ' | Quantity=' || v_sales(i).total_qty ||
            ' | Revenue=' || ROUND(v_sales(i).total_revenue, 2)
        );
END LOOP;

DBMS_OUTPUT.PUT_LINE('End list items');
END pr_top_selling_items;
/

BEGIN
pr_top_selling_items ('11-11-2025','12-11-2025', 10);
END;


-- Trigger for Updating Menu Availability
CREATE OR REPLACE TRIGGER trg_update_menu_availability
AFTER UPDATE OF current_stock ON ingredients
FOR EACH ROW
DECLARE
CURSOR c_menu IS
SELECT DISTINCT mr.menu_item_id
FROM   menu_recipes mr
WHERE  mr.ingredient_id = :NEW.ingredient_id;

r_menu c_menu%ROWTYPE;
BEGIN
IF :NEW.current_stock <= 0 THEN OPEN c_menu;
LOOP
FETCH c_menu INTO r_menu;
EXIT WHEN c_menu%NOTFOUND;

UPDATE menu_items
SET    is_available = 'No'
WHERE  menu_item_id = r_menu.menu_item_id; 
END LOOP;
CLOSE c_menu;
END IF;
END;
/

--Testing
UPDATE ingredients
SET    current_stock = 0
WHERE  ingredient_id = 6;


SELECT mr.menu_item_id,mi.item_name, mi.is_available
FROM   menu_recipes mr
JOIN menu_items mi
ON mi.menu_item_id = mr.menu_item_id
WHERE  mr.ingredient_id = 6;


-- Package for Menu Insights
CREATE OR REPLACE PACKAGE pkg_menu_insights AS

PROCEDURE pr_hero_items
(p_top_n_per_cat  IN PLS_INTEGER DEFAULT 2);

PROCEDURE pr_dead_items
(p_max_qty   IN NUMBER DEFAULT 3);

END pkg_menu_insights;
/

-- Package Body for Menu Insights
CREATE OR REPLACE PACKAGE BODY pkg_menu_insights AS
-- Procedure for mostly selled menu items per category
PROCEDURE pr_hero_items
(p_top_n_per_cat  IN PLS_INTEGER) IS
CURSOR c_cat IS
SELECT DISTINCT m.category
FROM customer_orders o
JOIN customer_order_details d ON d.order_id = o.order_id
JOIN menu_items m ON m.menu_item_id = d.menu_item_id
WHERE  o.order_status = 'Ready'
ORDER BY m.category;

v_count PLS_INTEGER;
BEGIN
DBMS_OUTPUT.PUT_LINE('HERO ITEMS PER CATEGORY');

FOR c IN c_cat LOOP
      DBMS_OUTPUT.PUT_LINE(' ');
      DBMS_OUTPUT.PUT_LINE('Category: ' || c.category);
      DBMS_OUTPUT.PUT_LINE('Top ' || p_top_n_per_cat || ' items:');

v_count := 0;

FOR r IN (SELECT m.menu_item_id,m.item_name,
SUM(d.quantity) AS total_qty,
SUM(d.quantity * d.unit_price) AS total_revenue
FROM customer_orders o
JOIN customer_order_details d ON d.order_id = o.order_id
JOIN menu_items m ON m.menu_item_id = d.menu_item_id
WHERE o.order_status = 'Ready'AND m.category = c.category
GROUP BY m.menu_item_id, m.item_name
ORDER BY total_revenue DESC) LOOP
v_count := v_count + 1;
IF v_count > p_top_n_per_cat THEN
EXIT;
END IF;

DBMS_OUTPUT.PUT_LINE(
          '  #' || v_count ||
          ' | ID=' || r.menu_item_id ||
          ' | ' || r.item_name ||
          ' | qty=' || r.total_qty ||
          ' | revenue=' || r.total_revenue);
END LOOP;
END LOOP;

DBMS_OUTPUT.PUT_LINE('END HERO ITEMS');
END pr_hero_items;
-- Procedure for rarely selled menu items
PROCEDURE pr_dead_items(
p_max_qty   IN NUMBER) IS
CURSOR c_dead IS
SELECT m.menu_item_id, m.item_name, m.category, NVL(SUM(d.quantity), 0) AS total_qty
FROM menu_items m
LEFT JOIN customer_order_details d ON d.menu_item_id = m.menu_item_id
LEFT JOIN customer_orders o ON o.order_id = d.order_id
AND o.order_status = 'Served'
GROUP BY m.menu_item_id, m.item_name, m.category
HAVING NVL(SUM(d.quantity), 0) <= p_max_qty
ORDER BY total_qty, m.category, m.item_name;
BEGIN
DBMS_OUTPUT.PUT_LINE('DEAD ITEMS (quantity <= ' || p_max_qty || ')');

FOR r IN c_dead LOOP
      DBMS_OUTPUT.PUT_LINE(
        'Id=' || r.menu_item_id ||
        ' | ' || r.item_name ||
        ' | category=' || r.category ||
        ' | total_qty=' || r.total_qty
      );
END LOOP;

DBMS_OUTPUT.PUT_LINE('END DEAD ITEMS');
END pr_dead_items;

END pkg_menu_insights;
/

BEGIN
  pkg_menu_insights.pr_hero_items(p_top_n_per_cat => 4);
END;
/

BEGIN
  pkg_menu_insights.pr_dead_items(p_max_qty => 3);
END;
/



-- Package for customer behaviour 
CREATE OR REPLACE PACKAGE pkg_customer_behavior IS

  TYPE t_category_nt IS TABLE OF VARCHAR2(100);

  PROCEDURE pr_customer_order_summary(
    p_customer_id IN Customers.customer_id%TYPE
  );

  FUNCTION fn_customer_favorite_item(
    p_customer_id IN Customers.customer_id%TYPE
  ) RETURN VARCHAR2;

  PROCEDURE pr_customer_recommendation_report(
    p_customer_id IN Customers.customer_id%TYPE
  );

END pkg_customer_behavior;
/

CREATE OR REPLACE PACKAGE BODY pkg_customer_behavior IS

  PROCEDURE pr_customer_order_summary(
    p_customer_id IN customers.customer_id%TYPE
  )
  IS
    v_full_name    VARCHAR2(200);
    v_order_count  NUMBER;
    v_total_amount NUMBER;
    v_first_order  DATE;
    v_last_order   DATE;
  BEGIN
    BEGIN
      SELECT c.first_name || ' ' || c.last_name
      INTO   v_full_name
      FROM   customers c
      WHERE  c.customer_id = p_customer_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Customer with ID '||p_customer_id||' not found.');
        RETURN;
    END;

    SELECT COUNT(*),
           NVL(SUM(co.total_amount), 0),
           MIN(co.order_date),
           MAX(co.order_date)
    INTO   v_order_count,
           v_total_amount,
           v_first_order,
           v_last_order
    FROM   customer_orders co
    WHERE  co.customer_id  = p_customer_id
    AND    co.order_status = 'Ready';

    DBMS_OUTPUT.PUT_LINE('Customer Order Summary');
    DBMS_OUTPUT.PUT_LINE('Customer: '||v_full_name||' (ID: '||p_customer_id||')');
    DBMS_OUTPUT.PUT_LINE('Total orders: '||v_order_count);
    DBMS_OUTPUT.PUT_LINE('Total spent: '||v_total_amount);
    DBMS_OUTPUT.PUT_LINE('First order date: '||TO_CHAR(v_first_order, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE('Last  order date: '||TO_CHAR(v_last_order, 'YYYY-MM-DD'));
  END pr_customer_order_summary;


  FUNCTION fn_customer_favorite_item(
    p_customer_id IN customers.customer_id%TYPE
  ) RETURN VARCHAR2
  IS
    v_item_name menu_items.item_name%TYPE;
  BEGIN
    SELECT item_name
    INTO   v_item_name
    FROM (
      SELECT mi.item_name,
             SUM(cod.quantity) AS total_qty
      FROM   customer_orders        co
             JOIN customer_order_details cod ON cod.order_id    = co.order_id
             JOIN menu_items        mi      ON mi.menu_item_id  = cod.menu_item_id
      WHERE  co.customer_id  = p_customer_id
      AND    co.order_status = 'Ready'
      GROUP BY mi.item_name
      ORDER BY SUM(cod.quantity) DESC, COUNT(*) DESC
    )
    WHERE ROWNUM = 1;

    RETURN v_item_name;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END fn_customer_favorite_item;


  PROCEDURE pr_customer_recommendation_report(
    p_customer_id IN customers.customer_id%TYPE
  )
  IS
    v_top_category   menu_items.category%TYPE;
    v_cat_count      NUMBER;

    v_item_name_1    menu_items.item_name%TYPE;
    v_item_name_2    menu_items.item_name%TYPE;
    v_item_name_3    menu_items.item_name%TYPE;
  BEGIN
    BEGIN
      SELECT category,
             total_qty
      INTO   v_top_category,
             v_cat_count
      FROM (
        SELECT mi.category,
               SUM(cod.quantity) AS total_qty
        FROM   customer_orders co
               JOIN customer_order_details cod ON cod.order_id    = co.order_id
               JOIN menu_items             mi ON mi.menu_item_id  = cod.menu_item_id
        WHERE  co.customer_id  = p_customer_id
        AND    co.order_status = 'Ready'
        GROUP BY mi.category
        ORDER BY SUM(cod.quantity) DESC
      )
      WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('No orders found for customer '||p_customer_id);
        RETURN;
    END;

    BEGIN
      SELECT item_name
      INTO   v_item_name_1
      FROM (
        SELECT mi.item_name,
               SUM(cod.quantity) AS total_qty
        FROM   customer_orders co
               JOIN customer_order_details cod ON cod.order_id    = co.order_id
               JOIN menu_items             mi ON mi.menu_item_id  = cod.menu_item_id
        WHERE  co.customer_id  = p_customer_id
        AND    co.order_status = 'Ready'
        GROUP BY mi.item_name
        ORDER BY SUM(cod.quantity) DESC
      )
      WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_item_name_1 := NULL;
    END;

    BEGIN
      SELECT item_name
      INTO   v_item_name_2
      FROM (
        SELECT mi.item_name,
               SUM(cod.quantity) AS total_qty,
               ROW_NUMBER() OVER (ORDER BY SUM(cod.quantity) DESC) rn
        FROM   customer_orders co
               JOIN customer_order_details cod ON cod.order_id    = co.order_id
               JOIN menu_items             mi ON mi.menu_item_id  = cod.menu_item_id
        WHERE  co.customer_id  = p_customer_id
        AND    co.order_status = 'Ready'
        GROUP BY mi.item_name
      )
      WHERE rn = 2;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_item_name_2 := NULL;
    END;

    BEGIN
      SELECT item_name
      INTO   v_item_name_3
      FROM (
        SELECT mi.item_name,
               SUM(cod.quantity) AS total_qty,
               ROW_NUMBER() OVER (ORDER BY SUM(cod.quantity) DESC) rn
        FROM   customer_orders co
               JOIN customer_order_details cod ON cod.order_id    = co.order_id
               JOIN menu_items             mi ON mi.menu_item_id  = cod.menu_item_id
        WHERE  co.customer_id  = p_customer_id
        AND    co.order_status = 'Ready'
        GROUP BY mi.item_name
      )
      WHERE rn = 3;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_item_name_3 := NULL;
    END;

    DBMS_OUTPUT.PUT_LINE('Customer Recommendation Report');
    DBMS_OUTPUT.PUT_LINE('Customer ID: '||p_customer_id);
    DBMS_OUTPUT.PUT_LINE('Top category: '||v_top_category||
                         ' (total items ordered: '||v_cat_count||')');
    DBMS_OUTPUT.PUT_LINE('Top 3 favorite items:');
    IF v_item_name_1 IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('1) '||v_item_name_1);
    END IF;
    IF v_item_name_2 IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('2) '||v_item_name_2);
    END IF;
    IF v_item_name_3 IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('3) '||v_item_name_3);
    END IF;
  END pr_customer_recommendation_report;

END pkg_customer_behavior;
/

--Testing
--1
BEGIN
  pkg_customer_behavior.pr_customer_order_summary(66);
END;
/
--2
DECLARE
  v_fav_item  menu_items.item_name%TYPE;
BEGIN
  v_fav_item := pkg_customer_behavior.fn_customer_favorite_item(66);
  DBMS_OUTPUT.PUT_LINE('Favorite item: ' || NVL(v_fav_item, 'no data'));
END;
/
--3
BEGIN
  pkg_customer_behavior.pr_customer_recommendation_report(66);
END;
/

--Package for reservation
CREATE OR REPLACE PACKAGE pkg_reservation_and_tables IS

  FUNCTION fn_reservation_showup_rate(
    p_from_date IN DATE,
    p_to_date   IN DATE
  ) RETURN NUMBER;

  PROCEDURE pr_reservation_showup_statistics(
    p_from_date IN DATE,
    p_to_date   IN DATE
  );
  PROCEDURE pr_table_performance_summary(
    p_from_date IN DATE,
    p_to_date   IN DATE
  );

END pkg_reservation_and_tables;
/

CREATE OR REPLACE PACKAGE BODY pkg_reservation_and_tables IS

  FUNCTION fn_reservation_showup_rate(
    p_from_date IN DATE,
    p_to_date   IN DATE
  ) RETURN NUMBER
  IS
    v_total   NUMBER := 0;
    v_showups NUMBER := 0;
    v_rate    NUMBER := 0;
  BEGIN
    SELECT COUNT(*) AS total_res,
           SUM(CASE WHEN UPPER(r.status) = 'YES' THEN 1 ELSE 0 END) AS showups
    INTO   v_total,
           v_showups
    FROM   reservations r
    WHERE  TO_DATE(r.reservation_datetime, 'DD/MM/YYYY')
              BETWEEN TRUNC(p_from_date) AND TRUNC(p_to_date);

    IF v_total = 0 THEN
      RETURN 0;
    END IF;

    v_rate := (v_showups / v_total) * 100;
    RETURN ROUND(v_rate, 2);
  EXCEPTION
    WHEN OTHERS THEN
      RETURN 0;
  END fn_reservation_showup_rate;

    PROCEDURE pr_reservation_showup_statistics(
    p_from_date IN DATE,
    p_to_date   IN DATE
  )
  IS
    v_cur_date  DATE;
    v_total     NUMBER;
    v_showups   NUMBER;
    v_no_shows  NUMBER;
    v_rate      NUMBER;
  BEGIN
    DBMS_OUTPUT.PUT_LINE('Reservation Show-Up Statistics');
    DBMS_OUTPUT.PUT_LINE('Period: '||
                         TO_CHAR(TRUNC(p_from_date),'YYYY-MM-DD')||' .. '||
                         TO_CHAR(TRUNC(p_to_date),'YYYY-MM-DD'));

    v_cur_date := TRUNC(p_from_date);

    WHILE v_cur_date <= TRUNC(p_to_date) LOOP

      SELECT COUNT(*) AS total_res,
             NVL(SUM(CASE
                   WHEN UPPER(r.status) = 'YES' THEN 1
                   ELSE 0
                 END),0) AS showups
      INTO   v_total,
             v_showups
      FROM   reservations r
      WHERE  TO_DATE(r.reservation_datetime, 'DD/MM/YYYY') = v_cur_date;

      v_no_shows := v_total - v_showups;

      IF v_total = 0 THEN
        v_rate := 0;
      ELSE
        v_rate := (v_showups / v_total) * 100;
      END IF;

      INSERT INTO reservation_showup_stats (
        stat_date,
        total_reservations,
        showups,
        no_shows,
        showup_rate
      ) VALUES (
        v_cur_date,
        v_total,
        v_showups,
        v_no_shows,
        ROUND(v_rate, 2)
      );

      DBMS_OUTPUT.PUT_LINE(
        TO_CHAR(v_cur_date, 'YYYY-MM-DD') ||
        ' | total=' || v_total ||
        ', showups=' || v_showups ||
        ', no_shows=' || v_no_shows ||
        ', rate=' || ROUND(v_rate, 2) || '%'
      );

      v_cur_date := v_cur_date + 1;
    END LOOP;
  END pr_reservation_showup_statistics;


  PROCEDURE pr_table_performance_summary(
  p_from_date IN DATE,
  p_to_date   IN DATE
  )
  IS
   CURSOR c_tables IS
     SELECT t.table_id,
           t.location,
           t.capacity,
           NVL(COUNT(r.reservation_id), 0) AS res_count,
           NVL(AVG(r.party_size), 0)       AS avg_party
     FROM   tables t
           LEFT JOIN reservations r
             ON r.table_id = t.table_id
            AND TO_DATE(r.reservation_datetime, 'DD/MM/YYYY')
                  BETWEEN TRUNC(p_from_date) AND TRUNC(p_to_date)
     GROUP BY t.table_id, t.location, t.capacity
     ORDER BY res_count DESC;  
  BEGIN
   DBMS_OUTPUT.PUT_LINE('Table Performance Summary');
   DBMS_OUTPUT.PUT_LINE(
    'Period: ' ||
    TO_CHAR(TRUNC(p_from_date),'YYYY-MM-DD') || ' .. ' ||
    TO_CHAR(TRUNC(p_to_date)  ,'YYYY-MM-DD')
  );

  FOR t IN c_tables LOOP
    DBMS_OUTPUT.PUT_LINE(
      'Table ' || t.table_id ||
      ' (' || t.location || ', capacity=' || t.capacity || ')' ||
      ' | reservations=' || t.res_count ||
      ', avg_party=' || ROUND(t.avg_party)
    );
  END LOOP;
  
 END pr_table_performance_summary;

END pkg_reservation_and_tables;
/

--Testing
DECLARE
  v_rate NUMBER;
BEGIN
  v_rate := pkg_reservation_and_tables.fn_reservation_showup_rate(
              p_from_date => DATE '2025-11-10',
              p_to_date   => DATE '2025-11-20'
            );
  DBMS_OUTPUT.PUT_LINE('FN: Show-up rate');
  DBMS_OUTPUT.PUT_LINE('Rate: ' || v_rate || '%');
  DBMS_OUTPUT.PUT_LINE(' ');

  DBMS_OUTPUT.PUT_LINE('PR: Daily show-up stats');
  pkg_reservation_and_tables.pr_reservation_showup_statistics(
    p_from_date => DATE '2025-11-10',
    p_to_date   => DATE '2025-11-20'
  );

  DBMS_OUTPUT.PUT_LINE(' ');
  DBMS_OUTPUT.PUT_LINE(' PR: Table performance summary');
  pkg_reservation_and_tables.pr_table_performance_summary(
    p_from_date => DATE '2025-11-10',
    p_to_date   => DATE '2025-11-20'
  );
END;
/

--Trigger for capacity
CREATE OR REPLACE TRIGGER trg_reservation_capacity_check
BEFORE INSERT OR UPDATE OF party_size, table_id ON reservations
FOR EACH ROW
DECLARE
  v_capacity tables.capacity%TYPE;
BEGIN
  SELECT capacity
  INTO   v_capacity
  FROM   tables
  WHERE  table_id = :NEW.table_id;

  IF :NEW.party_size <= v_capacity THEN
    DBMS_OUTPUT.PUT_LINE(
      'Reservation OK: party_size=' || :NEW.party_size ||
      ' fits in table ' || :NEW.table_id ||
      ' (capacity=' || v_capacity || ')'
    );
  ELSE
    DBMS_OUTPUT.PUT_LINE(
      'Our cafe follows the laws of physics — choose a larger table: party_size=' || :NEW.party_size ||
      ' exceeds table capacity=' || v_capacity
    );
  END IF;
END;
/

--Testing
INSERT INTO reservations (table_id, reservation_datetime, party_size)
VALUES (1, SYSDATE, 7);

INSERT INTO reservations (table_id, reservation_datetime, party_size)
VALUES (1, SYSDATE, 4);

-- Package for employee shifts
CREATE OR REPLACE PACKAGE pkg_employee_shifts IS

  PROCEDURE pr_employee_shift_summary_coll(
    p_from_date IN DATE,
    p_to_date   IN DATE
  );

END pkg_employee_shifts;
/

CREATE OR REPLACE PACKAGE BODY pkg_employee_shifts IS

  TYPE t_emp_shift_rec IS RECORD (
    employee_id   employees.employee_id%TYPE,
    first_name    employees.first_name%TYPE,
    last_name     employees.last_name%TYPE,
    role          employees.role%TYPE,
    hours_worked  NUMBER,
    late_hours    NUMBER
  );

  TYPE t_emp_shift_tab IS TABLE OF t_emp_shift_rec;

  PROCEDURE pr_employee_shift_summary_coll(
    p_from_date IN DATE,
    p_to_date   IN DATE
  )
  IS
    l_emp_tab         t_emp_shift_tab;
    v_total_hours     NUMBER := 0;
    v_total_late_hrs  NUMBER := 0;

    v_max_late_hrs    NUMBER := 0;
    v_max_emp_id      employees.employee_id%TYPE;
    v_max_first_name  employees.first_name%TYPE;
    v_max_last_name   employees.last_name%TYPE;
    v_max_role        employees.role%TYPE;
  BEGIN
    SELECT
      e.employee_id,
      e.first_name,
      e.last_name,
      e.role,

        SUM(
          (
            TO_DATE(es.shift_date || ' ' || es.end_time,
                    'MM/DD/YYYY HH24:MI')
            -
            TO_DATE(es.shift_date || ' ' || es.start_time,
                    'MM/DD/YYYY HH24:MI')
          ) * 24
        ),
        0
      ) AS hours_worked,

      NVL(SUM(GREATEST((TO_DATE(es.shift_date || ' ' || es.start_time,
                      'MM/DD/YYYY HH24:MI') -
            TO_DATE(es.shift_date || ' ' ||
                CASE
                  WHEN TO_NUMBER(SUBSTR(es.start_time, 1, 2)) < 12
                    THEN '08:00'   
                  ELSE '15:00'     
                END,
                'MM/DD/YYYY HH24:MI')) * 24,0)),0) AS late_hours

    BULK COLLECT INTO l_emp_tab
    FROM   employees e
           LEFT JOIN employee_shifts es
             ON es.employee_id = e.employee_id
            AND TO_DATE(es.shift_date, 'MM/DD/YYYY')
                  BETWEEN TRUNC(p_from_date) AND TRUNC(p_to_date)
    GROUP BY e.employee_id, e.first_name, e.last_name, e.role
    ORDER BY hours_worked DESC, e.employee_id;

    DBMS_OUTPUT.PUT_LINE('=== Employee Shift Summary (with lateness in hours) ===');
    DBMS_OUTPUT.PUT_LINE(
      'Period: ' ||
      TO_CHAR(TRUNC(p_from_date), 'YYYY-MM-DD') || ' .. ' ||
      TO_CHAR(TRUNC(p_to_date),   'YYYY-MM-DD')
    );
    DBMS_OUTPUT.PUT_LINE(
      'ID | Name              | Role        | Hours | Late (hours)'
    );

    FOR i IN 1 .. l_emp_tab.COUNT LOOP
      DBMS_OUTPUT.PUT_LINE(
        l_emp_tab(i).employee_id || ' | ' ||
        l_emp_tab(i).first_name || ' ' || l_emp_tab(i).last_name ||
        ' | ' || l_emp_tab(i).role ||
        ' | hours=' || ROUND(l_emp_tab(i).hours_worked, 2) ||
        ' | late_h='  || ROUND(l_emp_tab(i).late_hours, 2)
      );

      v_total_hours    := v_total_hours    + l_emp_tab(i).hours_worked;
      v_total_late_hrs := v_total_late_hrs + l_emp_tab(i).late_hours;

      IF l_emp_tab(i).late_hours > v_max_late_hrs THEN
        v_max_late_hrs   := l_emp_tab(i).late_hours;
        v_max_emp_id     := l_emp_tab(i).employee_id;
        v_max_first_name := l_emp_tab(i).first_name;
        v_max_last_name  := l_emp_tab(i).last_name;
        v_max_role       := l_emp_tab(i).role;
      END IF;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE(
      'TOTAL HOURS: ' || ROUND(v_total_hours, 2)
    );
    DBMS_OUTPUT.PUT_LINE(
      'TOTAL LATE (hours): ' || ROUND(v_total_late_hrs, 2)
    );


    IF v_max_late_hrs > 0 THEN
      DBMS_OUTPUT.PUT_LINE(
        'Most late employee: ' ||
        v_max_emp_id || ' - ' ||
        v_max_first_name || ' ' || v_max_last_name ||
        ' | role=' || v_max_role ||
        ' | late=' || ROUND(v_max_late_hrs, 2) || ' hours'
      );
    ELSE
      DBMS_OUTPUT.PUT_LINE('No one was late in this period.');
    END IF;
  END pr_employee_shift_summary_coll;

END pkg_employee_shifts;
/

--Testing
BEGIN
  pkg_employee_shifts.pr_employee_shift_summary_coll(
    p_from_date => DATE '2025-11-12',
    p_to_date   => DATE '2025-12-01'
  );
END;
/



-- Package for waste analysis
CREATE OR REPLACE PACKAGE pkg_waste_analysis IS

  FUNCTION fn_get_daily_waste_cost (
    p_date IN DATE
  ) RETURN NUMBER;

  FUNCTION fn_get_monthly_waste_cost (
    p_year  IN NUMBER,
    p_month IN NUMBER
  ) RETURN NUMBER;

  PROCEDURE pr_top_waste_reasons (
    p_from_date IN DATE DEFAULT NULL,
    p_to_date   IN DATE DEFAULT NULL
  );

  PROCEDURE pr_waste_rate_per_ingredient (
    p_from_date IN DATE DEFAULT NULL,
    p_to_date   IN DATE DEFAULT NULL
  );

  PROCEDURE pr_late_delivery_waste_impact;

  PROCEDURE pr_waste_per_employee;

END pkg_waste_analysis;
/


CREATE OR REPLACE PACKAGE BODY pkg_waste_analysis IS

  FUNCTION fn_get_daily_waste_cost (
      p_date IN DATE
  ) RETURN NUMBER IS
      v_total_cost NUMBER;
  BEGIN
      SELECT NVL(SUM(il.quantity_changed * i.unit_price), 0)
      INTO   v_total_cost
      FROM   wastage_log wl
             JOIN inventory_log il
               ON il.log_id = wl.log_id
             JOIN ingredients i
               ON i.ingredient_id = il.ingredient_id
      WHERE  il.change_type = 'Waste'
         AND TRUNC(il.change_date) = TRUNC(p_date);

      RETURN v_total_cost;

  EXCEPTION
      WHEN NO_DATA_FOUND THEN
          RETURN 0;
  END fn_get_daily_waste_cost;

  FUNCTION fn_get_monthly_waste_cost (
      p_year  IN NUMBER,
      p_month IN NUMBER
  ) RETURN NUMBER IS
      v_total_cost NUMBER;
  BEGIN
      SELECT NVL(SUM(il.quantity_changed * i.unit_price), 0)
      INTO   v_total_cost
      FROM   wastage_log wl
             JOIN inventory_log il
               ON il.log_id = wl.log_id
             JOIN ingredients i
               ON i.ingredient_id = il.ingredient_id
      WHERE  il.change_type = 'Waste'
         AND EXTRACT(YEAR  FROM il.change_date) = p_year
         AND EXTRACT(MONTH FROM il.change_date) = p_month;

      RETURN v_total_cost;
  EXCEPTION
      WHEN NO_DATA_FOUND THEN
          RETURN 0;
  END fn_get_monthly_waste_cost;

  PROCEDURE pr_top_waste_reasons (
      p_from_date IN DATE DEFAULT NULL, 
      p_to_date   IN DATE DEFAULT NULL  
  ) IS
      v_has_data BOOLEAN := FALSE;
  BEGIN
      DBMS_OUTPUT.PUT_LINE('Top Waste Reasons');

      FOR r IN (
          SELECT
              wl.reason_type,
              SUM(il.quantity_changed)                AS total_quantity_wasted,
              SUM(il.quantity_changed * i.unit_price) AS total_waste_cost
          FROM   wastage_log wl
                 JOIN inventory_log il
                   ON il.log_id = wl.log_id
                 JOIN ingredients i
                   ON i.ingredient_id = il.ingredient_id
          WHERE  il.change_type = 'Waste'
             AND (p_from_date IS NULL OR il.change_date >= p_from_date)
             AND (p_to_date   IS NULL OR il.change_date <= p_to_date)
          GROUP BY wl.reason_type
          ORDER BY total_waste_cost DESC
      ) LOOP
          v_has_data := TRUE;

          DBMS_OUTPUT.PUT_LINE(
                'Reason: ' || r.reason_type
             || ' | Quantity wasted: ' || r.total_quantity_wasted
             || ' | Cost: ' || r.total_waste_cost
          );
      END LOOP;
      
      IF NOT v_has_data THEN
          DBMS_OUTPUT.PUT_LINE('No waste records found for given period.');
      END IF;

  EXCEPTION
      WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE(
              'Error in pr_top_waste_reasons: ' || SQLERRM
          );
  END pr_top_waste_reasons;

  PROCEDURE pr_waste_rate_per_ingredient (
      p_from_date IN DATE DEFAULT NULL,   
      p_to_date   IN DATE DEFAULT NULL    
  ) IS
      v_waste_rate NUMBER;
      v_has_data   BOOLEAN := FALSE;
  BEGIN
      DBMS_OUTPUT.PUT_LINE('Waste Rate per Ingredient');
      DBMS_OUTPUT.PUT_LINE('ID | Name | Waste Qty | Consumed Qty | Waste %');

      FOR r IN (
          SELECT
              i.ingredient_id,
              i.ingredient_name,

              SUM(
                  CASE 
                      WHEN il.change_type = 'Waste' 
                      THEN ABS(il.quantity_changed)
                      ELSE 0
                  END
              ) AS total_waste_qty,

              SUM(
                  CASE 
                      WHEN il.change_type IN ('Usage', 'Waste') 
                      THEN ABS(il.quantity_changed)
                      ELSE 0
                  END
              ) AS total_consumed_qty

          FROM   ingredients i
                 JOIN inventory_log il
                   ON il.ingredient_id = i.ingredient_id
          WHERE  (p_from_date IS NULL OR il.change_date >= p_from_date)
             AND (p_to_date   IS NULL OR il.change_date <= p_to_date)
          GROUP BY
              i.ingredient_id,
              i.ingredient_name
          ORDER BY
              SUM(
                  CASE 
                      WHEN il.change_type = 'Waste' 
                      THEN ABS(il.quantity_changed)
                      ELSE 0
                  END
              ) / NULLIF(
                  SUM(
                      CASE 
                          WHEN il.change_type IN ('Usage', 'Waste') 
                          THEN ABS(il.quantity_changed)
                          ELSE 0
                      END
                  ), 0
              ) DESC NULLS LAST
      ) LOOP
          v_has_data := TRUE;

          IF r.total_consumed_qty > 0 THEN
              v_waste_rate := (r.total_waste_qty / r.total_consumed_qty) * 100;
          ELSE
              v_waste_rate := NULL; 
          END IF;

          DBMS_OUTPUT.PUT_LINE(
                r.ingredient_id
             || ' | ' || r.ingredient_name
             || ' | ' || r.total_waste_qty
             || ' | ' || r.total_consumed_qty
             || ' | ' || NVL(TO_CHAR(ROUND(v_waste_rate, 2)), 'N/A')
          );
      END LOOP;

      IF NOT v_has_data THEN
          DBMS_OUTPUT.PUT_LINE('No data found for given period.');
      END IF;

  EXCEPTION
      WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE(
              'Error in pr_waste_rate_per_ingredient: ' || SQLERRM
          );

  END pr_waste_rate_per_ingredient;

  PROCEDURE pr_late_delivery_waste_impact IS
  BEGIN
      DBMS_OUTPUT.PUT_LINE('Impact of Late Deliveries on Waste');

      FOR r IN (
          WITH delivery_stats AS (
              SELECT
                  so.supplier_id,
                  sod.ingredient_id,
                  COUNT(*) AS total_deliveries,
                  SUM(
                      CASE 
                        WHEN sod.delivery_date > so.expected_delivery_date 
                        THEN 1 
                        ELSE 0 
                      END
                  ) AS late_deliveries
              FROM   supply_orders so
                     JOIN supply_order_details sod
                       ON so.supply_order_id = sod.supply_order_id
              GROUP BY so.supplier_id, sod.ingredient_id
          ),
          waste_stats AS (
              SELECT
                  i.supplier_id,
                  il.ingredient_id,
                  SUM(
                      CASE 
                        WHEN il.change_type = 'Waste'
                        THEN ABS(il.quantity_changed)
                        ELSE 0 
                      END
                  ) AS total_waste
              FROM   inventory_log il
                     JOIN ingredients i
                       ON i.ingredient_id = il.ingredient_id
              GROUP BY i.supplier_id, il.ingredient_id
          )
          SELECT
              d.supplier_id,
              s.first_name || ' ' || s.last_name AS supplier_name,
              SUM(d.late_deliveries) AS total_late,
              SUM(d.total_deliveries) AS total_deliveries,
              ROUND(
                SUM(d.late_deliveries) / NULLIF(SUM(d.total_deliveries), 0) * 100,
                2
              ) AS late_rate_percent,
              SUM(w.total_waste) AS total_waste
          FROM delivery_stats d
               JOIN waste_stats w
                 ON w.ingredient_id = d.ingredient_id
               JOIN suppliers s
                 ON s.supplier_id = d.supplier_id
          GROUP BY d.supplier_id, s.first_name, s.last_name
          ORDER BY late_rate_percent DESC
      ) LOOP
          DBMS_OUTPUT.PUT_LINE(
                'Supplier: ' || r.supplier_name
             || ' | Late deliveries: ' || r.total_late || '/' || r.total_deliveries
             || ' | Late rate: ' || r.late_rate_percent || '%'
             || ' | Total waste: ' || r.total_waste
          );
      END LOOP;

  END pr_late_delivery_waste_impact;

  PROCEDURE pr_waste_per_employee IS
    CURSOR c_waste_per_employee IS
        SELECT
            e.employee_id,
            e.first_name || ' ' || e.last_name AS employee_name,
            e.role                              AS employee_role, 
            SUM(ABS(il.quantity_changed))       AS total_waste_qty,
            SUM(ABS(il.quantity_changed) * i.unit_price) AS total_waste_cost
        FROM   inventory_log il
               JOIN wastage_log w
                 ON w.log_id = il.log_id
               JOIN ingredients i
                 ON i.ingredient_id = il.ingredient_id
               LEFT JOIN employee_shifts es
                 ON es.shift_id = il.shift_id
               LEFT JOIN employees e
                 ON e.employee_id = es.employee_id
        WHERE  UPPER(il.change_type) = 'WASTE'
        GROUP BY
            e.employee_id,
            e.first_name,
            e.last_name,
            e.role
        ORDER BY
            total_waste_cost DESC;

    v_rec c_waste_per_employee%ROWTYPE;
  BEGIN
      DBMS_OUTPUT.PUT_LINE('Waste per Employee');
      DBMS_OUTPUT.PUT_LINE('ID | Name | Role | Waste Qty | Waste Cost');

      OPEN c_waste_per_employee;

      LOOP
          FETCH c_waste_per_employee INTO v_rec;
          EXIT WHEN c_waste_per_employee%NOTFOUND;

          DBMS_OUTPUT.PUT_LINE(
                NVL(TO_CHAR(v_rec.employee_id), 'N/A')
             || ' | ' || NVL(v_rec.employee_name, 'Unknown')
             || ' | ' || NVL(v_rec.employee_role, 'N/A')
             || ' | ' || NVL(TO_CHAR(v_rec.total_waste_qty), '0')
             || ' | ' || NVL(TO_CHAR(ROUND(v_rec.total_waste_cost, 2)), '0')
          );
      END LOOP;

      CLOSE c_waste_per_employee;
  END pr_waste_per_employee;

END pkg_waste_analysis;
/


-- Daily waste cost
SELECT pkg_waste_analysis.fn_get_daily_waste_cost(DATE '2025-11-12') AS waste_cost
FROM   dual;

-- Monthly waste cost
SELECT pkg_waste_analysis.fn_get_monthly_waste_cost(2025, 11) AS nov_waste_cost
FROM   dual;

-- Top waste reasons (all time)
BEGIN
  pkg_waste_analysis.pr_top_waste_reasons;
END;
/

-- Top waste reasons (for November 2025)
BEGIN
  pkg_waste_analysis.pr_top_waste_reasons(
    p_from_date => DATE '2025-11-01',
    p_to_date   => DATE '2025-11-30'
  );
END;
/

-- Waste rate per ingredient
BEGIN
  pkg_waste_analysis.pr_waste_rate_per_ingredient;
END;
/

-- Late delivery impact
BEGIN
  pkg_waste_analysis.pr_late_delivery_waste_impact;
END;
/

-- Waste per employee
BEGIN
  pkg_waste_analysis.pr_waste_per_employee;
END;
/

-- Trigger for reason require
CREATE OR REPLACE TRIGGER trg_wastage_reason_require
BEFORE INSERT OR UPDATE ON wastage_log
FOR EACH ROW
BEGIN
    IF :NEW.reason_type IS NULL
       OR TRIM(:NEW.reason_type) = '' THEN
        RAISE_APPLICATION_ERROR(
            -20020,
            'Reason for wastage is required'
        );
    END IF;
END;
/


INSERT INTO wastage_log (waste_id, log_id, reason_type)
VALUES (124, 10, NULL);

-- Creating alerts table for procedure
CREATE TABLE ingredient_alerts (
    alert_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingredient_id   NUMBER,
    ingredient_name VARCHAR2(200),
    alert_type      VARCHAR2(30),
    alert_message   VARCHAR2(400),
    alert_date      DATE DEFAULT SYSDATE,
    is_resolved     CHAR(1) DEFAULT 'N'
);

-- Procedure for warning expiry date 
CREATE OR REPLACE PROCEDURE pr_check_expiring_ingredients IS
BEGIN
    INSERT INTO ingredient_alerts (
        ingredient_id,
        ingredient_name,
        alert_type,
        alert_message
    )
    SELECT DISTINCT
           sod.ingredient_id,
           i.ingredient_name,
           'EXPIRING_SOON',
           'Ingredient "' || i.ingredient_name ||
           '" (ID ' || sod.ingredient_id ||
           ') will expire on ' || TO_CHAR(sod.expiry_date, 'YYYY-MM-DD') ||
           ' (only ' || ((sod.expiry_date) - (SYSDATE)) ||
           ' day(s) left). Please use this ingredient first.'
    FROM   supply_order_details sod
           JOIN ingredients i
             ON i.ingredient_id = sod.ingredient_id
    WHERE  sod.expiry_date BETWEEN (SYSDATE) AND (SYSDATE) + 2;
END pr_check_expiring_ingredients;
/


CREATE OR REPLACE TRIGGER trg_expiring_ingredient_alert
AFTER INSERT ON supply_order_details
FOR EACH ROW
DECLARE
    v_ingredient_name  ingredients.ingredient_name%TYPE;
    v_days_left        NUMBER;
BEGIN
    v_days_left := (:NEW.expiry_date) - (SYSDATE);
    IF v_days_left BETWEEN 0 AND 2 THEN

        SELECT ingredient_name
        INTO   v_ingredient_name
        FROM   ingredients
        WHERE  ingredient_id = :NEW.ingredient_id;

        INSERT INTO ingredient_alerts (
            ingredient_id,
            ingredient_name,
            alert_type,
            alert_message
        )
        VALUES (
            :NEW.ingredient_id,
            v_ingredient_name,
            'EXPIRING_SOON',
            'Ingredient "' || v_ingredient_name ||
            '" (ID ' || :NEW.ingredient_id ||
            ') will expire on ' || TO_CHAR(:NEW.expiry_date, 'YYYY-MM-DD') ||
            ' — only ' || v_days_left || ' day(s) left. Please use this ingredient first.'
        );

    END IF;
END;
/

-- Inserting supply order details to see if really ingredinet going to show up
INSERT INTO supply_order_details
(order_detail_id, supply_order_id, ingredient_id, quantity_ordered, unit_price, delivery_date, expiry_date)
VALUES (999, 10, 34, 5, 3.50, SYSDATE, SYSDATE + 1);

-- To see how many ingredints in alert that needs to be used firstly
SELECT
    alert_id,
    ingredient_id,
    ingredient_name,
    alert_type,
    alert_message,
    alert_date
FROM ingredient_alerts
ORDER BY alert_id DESC;

-- Procedure that will immeaditely upload ingredints that needs to be used
CREATE OR REPLACE PROCEDURE pr_fill_expiry_alerts IS
BEGIN

    DELETE FROM ingredient_alerts
    WHERE alert_type = 'EXPIRING_SOON';

    INSERT INTO ingredient_alerts (
        ingredient_id,
        ingredient_name,
        alert_type,
        alert_message
    )
    SELECT DISTINCT
           sod.ingredient_id,
           i.ingredient_name,
           'EXPIRING_SOON',
           'Ingredient "' || i.ingredient_name ||
           '" (ID ' || sod.ingredient_id ||
           ') will expire on ' || TO_CHAR(sod.expiry_date, 'YYYY-MM-DD') ||
           ' (only ' || (sod.expiry_date - SYSDATE) ||
           ' day(s) left). Please use this ingredient first.'
    FROM   supply_order_details sod
           JOIN ingredients i
             ON i.ingredient_id = sod.ingredient_id
    WHERE  sod.expiry_date IS NOT NULL
       AND (sod.expiry_date - SYSDATE) BETWEEN 0 AND 3;  
END pr_fill_expiry_alerts;
/


BEGIN
    pr_fill_expiry_alerts;
END;
/

-- Pacjage for financial analysis
CREATE OR REPLACE PACKAGE pkg_financial_analysis IS

  PROCEDURE pr_revenue_by_payment_method;

  PROCEDURE pr_cancellation_impact;

END pkg_financial_analysis;
/

CREATE OR REPLACE PACKAGE BODY pkg_financial_analysis IS
  PROCEDURE pr_revenue_by_payment_method IS
      v_total_revenue NUMBER;
  BEGIN
      SELECT SUM(total_amount)
      INTO   v_total_revenue
      FROM   customer_orders;

      DBMS_OUTPUT.PUT_LINE('Revenue by Payment Method');
      DBMS_OUTPUT.PUT_LINE('Method | Revenue | Percent');

      FOR r IN (
          SELECT
              p.payment_method AS method,
              SUM(co.total_amount) AS revenue,
              ROUND(
                  SUM(co.total_amount) / NULLIF(v_total_revenue, 0) * 100,
                  2
              ) AS percent_share
          FROM   payments p
                 JOIN customer_orders co
                   ON p.order_id = co.order_id
          GROUP BY p.payment_method
          ORDER BY revenue DESC
      ) LOOP
          DBMS_OUTPUT.PUT_LINE(
                r.method
             || ' | ' || r.revenue
             || ' | ' || r.percent_share || '%'
          );
      END LOOP;
  END pr_revenue_by_payment_method;

  PROCEDURE pr_cancellation_impact IS
      v_ready    NUMBER;
      v_canceled NUMBER;
      v_percent  NUMBER;
  BEGIN
      SELECT
          NVL(SUM(CASE 
                    WHEN UPPER(TRIM(order_status)) = 'READY' 
                    THEN total_amount 
                  END), 0),
          NVL(SUM(CASE 
                    WHEN UPPER(TRIM(order_status)) = 'CANCELLED' 
                    THEN total_amount 
                  END), 0)
      INTO v_ready, v_canceled
      FROM customer_orders;

      IF v_ready + v_canceled = 0 THEN
          v_percent := 0;
      ELSE
          v_percent := ROUND(v_canceled / (v_ready + v_canceled) * 100, 2);
      END IF;

      DBMS_OUTPUT.PUT_LINE('Refunds / Cancellation Impact');
      DBMS_OUTPUT.PUT_LINE('Revenue (Ready Orders):      ' || v_ready);
      DBMS_OUTPUT.PUT_LINE('Lost Revenue (Cancelled):    ' || v_canceled);
      DBMS_OUTPUT.PUT_LINE('Percent Lost:                ' || v_percent || '%');
  END pr_cancellation_impact;
END pkg_financial_analysis;
/


BEGIN
  pkg_financial_analysis.pr_revenue_by_payment_method;
END;
/

BEGIN
  pkg_financial_analysis.pr_cancellation_impact;
END;
/




-- Function for app builder to show stockout levels of ingredients 
CREATE OR REPLACE FUNCTION fn_stockout_risk (
p_ingredient_id IN ingredients.ingredient_id%TYPE) RETURN VARCHAR2 IS
v_current_stock   ingredients.current_stock%TYPE;
v_reorder_level   ingredients.reorder_level%TYPE;
BEGIN
    SELECT current_stock, reorder_level
    INTO   v_current_stock, v_reorder_level
    FROM   ingredients
    WHERE  ingredient_id = p_ingredient_id;

    IF v_current_stock <= v_reorder_level THEN
        RETURN 'HIGH';
    ELSE
        RETURN 'LOW';
    END IF;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 'NO ING';
    WHEN OTHERS THEN
        RETURN 'ERROR';
END fn_stockout_risk;
/

-- Procedure to show all ingredient stockout levels
CREATE OR REPLACE PROCEDURE pr_show_stockout_risks IS

TYPE t_ing_list IS TABLE OF ingredients.ingredient_id%TYPE;

v_ids  t_ing_list;             
v_name ingredients.ingredient_name%TYPE;
v_risk VARCHAR2(20);

BEGIN
SELECT ingredient_id
BULK COLLECT INTO v_ids
FROM ingredients
ORDER BY ingredient_id;

DBMS_OUTPUT.PUT_LINE('=== Stockout Risk for ALL Ingredients ===');

FOR i IN 1 .. v_ids.COUNT LOOP
        
SELECT ingredient_name
INTO v_name
FROM ingredients
WHERE ingredient_id = v_ids(i);

v_risk := fn_stockout_risk(v_ids(i));

DBMS_OUTPUT.PUT_LINE(
            'ID: ' || v_ids(i) ||
            ' | Name: ' || v_name ||
            ' | Risk: ' || v_risk
        );
END LOOP;
END pr_show_stockout_risks;
/

BEGIN
    pr_show_stockout_risks;
END;
/

-- App builder codes:

-- Coloring buttons for high/low risk ingredients
SELECT
    i.ingredient_id,
    i.ingredient_name,
    i.unit,
    i.current_stock,
    i.reorder_level,
    i.unit_price,
    s.first_name || s.last_name AS main_supplier,

    fn_stockout_risk(i.ingredient_id) AS risk_raw,

    CASE fn_stockout_risk(i.ingredient_id)
        WHEN 'HIGH' THEN
            '<span style="background-color:#ffd9b3; color:#a65300; font-weight:bold; padding:2px 6px; border-radius:4px;">HIGH</span>'
        WHEN 'LOW' THEN
            '<span style="background-color:#ccffcc; color:#006600; font-weight:bold; padding:2px 6px; border-radius:4px;">LOW</span>'
        ELSE
            fn_stockout_risk(i.ingredient_id)
    END AS stockout_risk,

    CASE 
        WHEN fn_stockout_risk(i.ingredient_id) = 'HIGH' THEN
            '<a href="f?p=&APP_ID.:6:&SESSION.::NO::P6_INGREDIENT_ID:'⠵⠺⠺⠟⠺⠟⠞⠵⠺⠺⠟⠟⠞⠵⠵'" '||
            'class="t-Button t-Button--warning t-Button--small">Choose Supplier</a>'
        ELSE
            NULL
    END AS choose_supplier

FROM ingredients i
LEFT JOIN suppliers s
       ON s.supplier_id = i.supplier_id
ORDER BY risk_raw DESC, i.ingredient_name;

-- Choosing the best suppler
SELECT
    s.supplier_id,
    s.first_name || s.last_name AS supplier_name,
    isup.last_unit_price,
    isup.is_preferred,
    s.phone,
    s.email
FROM ingredient_suppliers isup
JOIN suppliers s
  ON s.supplier_id = isup.supplier_id
WHERE isup.ingredient_id = :P6_INGREDIENT_ID
ORDER BY isup.last_unit_price;

-- Process making order or inserting into supply_orders
DECLARE
    v_qty        NUMBER;
    v_unit_price NUMBER;
    v_total_cost NUMBER;
BEGIN
    v_qty        := NVL(:P6_ORDER_QTY, 0);
    v_unit_price := NVL(:P6_BEST_UNIT_PRICE, 0);

    v_total_cost := v_qty * v_unit_price;

    INSERT INTO supply_orders (
        supply_order_id,
        supplier_id,
        order_date,
        expected_delivery_date,
        status,
        total_cost
    )
    VALUES (
        121,
        :P6_BEST_SUPPLIER_ID,
        SYSDATE,
        SYSDATE + 3,
        'Pending',
        v_total_cost
    );

    :P6_SUPPLY_ORDER_ID := 121;
    :P6_TOTAL_COST      := TO_CHAR(v_total_cost);  
END;

-- Process of cancelling the order or deleting from supply_orders
BEGIN
    DELETE FROM supply_orders
    WHERE status = 'Pending';

    :P6_SUPPLY_ORDER_ID := NULL;
    :P6_TOTAL_COST      := NULL;
    :P6_ORDER_QTY       := NULL;
END;

