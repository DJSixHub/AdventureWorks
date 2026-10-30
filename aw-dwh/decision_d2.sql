/*
    D2: lectura diaria de ventas para comparar líneas con/sin descuento
    aplicado y recompra regular observada por cliente.
    Ingreso neto y descuento se agrupan por moneda transaccional. El margen
    estimado se calcula en USD con el costo vigente en la fecha de venta.
*/
USE AdventureWorks2022;
GO

-- Fechas iniciales del historial de ventas de AdventureWorks.
DECLARE @StartDate date = '20110101';
DECLARE @EndDate date = '20141231';
DECLARE @ProductID int = NULL;

;WITH SalesLines AS
(
    SELECT
        CONVERT(date, h.OrderDate) AS SaleDate,
        d.ProductID,
        p.Name AS ProductName,
        d.SpecialOfferID,
        so.Description AS OfferDescription,
        so.StartDate AS OfferStartDate,
        so.EndDate AS OfferEndDate,
        COALESCE(t.Name, N'Sin territorio') AS Territory,
        CASE WHEN h.OnlineOrderFlag = 1 THEN N'Online' ELSE N'Venta asistida' END
            AS SalesChannel,
        CASE WHEN c.StoreID IS NULL THEN N'Persona' ELSE N'Revendedor' END
            AS CustomerType,
        CASE WHEN d.UnitPriceDiscount > 0
             THEN N'Descuento aplicado' ELSE N'Sin descuento'
        END AS DiscountStatus,
        COALESCE(cr.FromCurrencyCode, N'USD') AS TransactionCurrency,
        d.OrderQty,
        d.UnitPrice,
        d.UnitPriceDiscount,
        d.LineTotal,
        CASE WHEN d.UnitPriceDiscount > 0
             THEN CONVERT(decimal(19, 4), d.OrderQty)
                  * CONVERT(decimal(19, 4), d.UnitPrice)
                  * CONVERT(decimal(19, 8), d.UnitPriceDiscount)
             ELSE CONVERT(decimal(19, 8), 0)
        END AS DiscountAmount,
        CASE WHEN d.UnitPriceDiscount > 0
             THEN CONVERT(decimal(19, 4), d.OrderQty)
                  * CONVERT(decimal(19, 4), d.UnitPrice)
             ELSE CONVERT(decimal(19, 4), 0)
        END AS DiscountBaseAmount,
        pch.StandardCost,
        fx.ToUSD,
        CASE WHEN pch.StandardCost IS NOT NULL AND fx.ToUSD IS NOT NULL
             THEN CONVERT(decimal(19, 4), d.LineTotal) * fx.ToUSD
                  - CONVERT(decimal(19, 4), d.OrderQty)
                    * CONVERT(decimal(19, 4), pch.StandardCost)
        END AS EstimatedGrossProfitUSD,
        CASE WHEN fx.ToUSD IS NOT NULL
             THEN CONVERT(decimal(19, 4), d.LineTotal) * fx.ToUSD
        END AS NetSalesUSD,
        CASE WHEN pch.StandardCost IS NOT NULL AND fx.ToUSD IS NOT NULL
             THEN CONVERT(decimal(19, 4), d.LineTotal) * fx.ToUSD
        END AS MarginEligibleNetSalesUSD
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON d.SalesOrderID = h.SalesOrderID
    INNER JOIN Production.Product AS p
        ON p.ProductID = d.ProductID
    INNER JOIN Sales.SpecialOffer AS so
        ON so.SpecialOfferID = d.SpecialOfferID
    LEFT JOIN Production.ProductCostHistory AS pch
        ON pch.ProductID = d.ProductID
       AND h.OrderDate >= pch.StartDate
       AND (pch.EndDate IS NULL
            OR h.OrderDate < DATEADD(day, 1, CONVERT(date, pch.EndDate)))
    INNER JOIN Sales.Customer AS c
        ON c.CustomerID = h.CustomerID
    LEFT JOIN Sales.SalesTerritory AS t
        ON t.TerritoryID = h.TerritoryID
    LEFT JOIN Sales.CurrencyRate AS cr
        ON cr.CurrencyRateID = h.CurrencyRateID
    CROSS APPLY
    (
        SELECT CONVERT(decimal(19, 8),
            CASE
                WHEN cr.CurrencyRateID IS NULL THEN 1
                WHEN cr.ToCurrencyCode = N'USD' THEN cr.AverageRate
                WHEN cr.FromCurrencyCode = N'USD'
                    THEN CONVERT(decimal(19, 8), 1)
                         / NULLIF(CONVERT(decimal(19, 8), cr.AverageRate), 0)
            END
        ) AS ToUSD
    ) AS fx
    WHERE h.Status = 5
      AND h.OrderDate >= @StartDate
      AND h.OrderDate < DATEADD(day, 1, @EndDate)
      AND (@ProductID IS NULL OR d.ProductID = @ProductID)
),
SalesTotals AS
(
    SELECT
        SaleDate,
        ProductID,
        ProductName,
        SpecialOfferID,
        OfferDescription,
        OfferStartDate,
        OfferEndDate,
        Territory,
        SalesChannel,
        CustomerType,
        DiscountStatus,
        TransactionCurrency,
        SUM(CONVERT(bigint, OrderQty)) AS UnitsSold,
        SUM(CASE WHEN UnitPriceDiscount > 0
                 THEN CONVERT(bigint, OrderQty) ELSE 0 END) AS DiscountedUnits,
        SUM(LineTotal) AS NetSalesInSourceCurrency,
        SUM(EstimatedGrossProfitUSD) AS EstimatedGrossProfitUSD,
        SUM(NetSalesUSD) AS NetSalesUSD,
        SUM(MarginEligibleNetSalesUSD) AS MarginEligibleNetSalesUSD,
        COUNT_BIG(*) AS SalesLineCount,
        COUNT_BIG(CASE WHEN StandardCost IS NOT NULL AND ToUSD IS NOT NULL
                       THEN 1 END) AS MarginEligibleLineCount,
        SUM(DiscountAmount) AS DiscountAmountOnEligibleLines,
        SUM(DiscountBaseAmount) AS GrossAmountOnEligibleLines
    FROM SalesLines
    GROUP BY
        SaleDate, ProductID, ProductName, SpecialOfferID, OfferDescription,
        OfferStartDate, OfferEndDate, Territory, SalesChannel, CustomerType,
        DiscountStatus,
        TransactionCurrency
)
SELECT
    *,
    CAST(EstimatedGrossProfitUSD / NULLIF(MarginEligibleNetSalesUSD, 0)
        AS decimal(9, 6)) AS EstimatedGrossMarginRate,
    CAST(CONVERT(decimal(19, 6), MarginEligibleLineCount)
        / NULLIF(SalesLineCount, 0)
        AS decimal(9, 6)) AS GrossMarginLineCoverageRate,
    CAST(DiscountAmountOnEligibleLines
        / NULLIF(GrossAmountOnEligibleLines, 0)
        AS decimal(9, 6)) AS EffectiveDiscountRate
FROM SalesTotals
ORDER BY SaleDate, ProductName, SpecialOfferID;

/*
    Recompra regular observada por cliente, producto y oferta dentro de la
    ventana consultada.
*/
;WITH DiscountPurchases AS
(
    SELECT
        h.CustomerID,
        d.ProductID,
        d.SpecialOfferID,
        MIN(h.OrderDate) AS FirstDiscountPurchase
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON d.SalesOrderID = h.SalesOrderID
    WHERE h.Status = 5
      AND h.OrderDate >= @StartDate
      AND h.OrderDate < DATEADD(day, 1, @EndDate)
      AND d.UnitPriceDiscount > 0
      AND (@ProductID IS NULL OR d.ProductID = @ProductID)
    GROUP BY h.CustomerID, d.ProductID, d.SpecialOfferID
),
CustomerOutcomes AS
(
    SELECT
        dp.CustomerID,
        dp.ProductID,
        dp.SpecialOfferID,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM Sales.SalesOrderHeader AS h2
            INNER JOIN Sales.SalesOrderDetail AS d2
                ON d2.SalesOrderID = h2.SalesOrderID
            WHERE h2.CustomerID = dp.CustomerID
              AND h2.Status = 5
              AND h2.OrderDate > dp.FirstDiscountPurchase
              AND h2.OrderDate < DATEADD(day, 1, @EndDate)
              AND d2.ProductID = dp.ProductID
              AND d2.UnitPriceDiscount = 0
        ) THEN 1 ELSE 0 END AS HasRegularRepurchase
    FROM DiscountPurchases AS dp
)
SELECT
    co.ProductID,
    p.Name AS ProductName,
    co.SpecialOfferID,
    so.Description AS OfferDescription,
    COUNT_BIG(*) AS CustomersWithDiscount,
    SUM(CONVERT(bigint, co.HasRegularRepurchase)) AS CustomersWithRegularRepurchase,
    CAST(
        SUM(CONVERT(decimal(19, 6), co.HasRegularRepurchase))
        / NULLIF(COUNT_BIG(*), 0)
        AS decimal(9, 6)
    ) AS ObservedRegularRepurchaseRate
FROM CustomerOutcomes AS co
INNER JOIN Production.Product AS p
    ON p.ProductID = co.ProductID
INNER JOIN Sales.SpecialOffer AS so
    ON so.SpecialOfferID = co.SpecialOfferID
GROUP BY co.ProductID, p.Name, co.SpecialOfferID, so.Description
ORDER BY p.Name, co.SpecialOfferID;
GO
