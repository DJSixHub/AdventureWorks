/*
    D7: existencias agregadas frente a umbrales de producto, distribución
    física y tendencia mensual de compras/recepciones.
    Solo lectura. Ejecutar contra AdventureWorks OLTP en SQL Server.
*/
USE AdventureWorks2022;
GO

DECLARE @CutoffDate date =
(
    SELECT MAX(CONVERT(date, OrderDate))
    FROM Purchasing.PurchaseOrderHeader
);

;WITH MaterialScope AS
(
    SELECT
        p.ProductID,
        p.Name AS ProductName,
        p.ProductNumber,
        p.ReorderPoint,
        p.SafetyStockLevel
    FROM Production.Product AS p
    INNER JOIN Production.ProductSubcategory AS ps
        ON ps.ProductSubcategoryID = p.ProductSubcategoryID
    INNER JOIN Production.ProductCategory AS pc
        ON pc.ProductCategoryID = ps.ProductCategoryID
    WHERE pc.Name = N'Components'
      AND p.MakeFlag = 0
      AND p.FinishedGoodsFlag = 0
),
ProductTotals AS
(
    SELECT pi.ProductID, SUM(CONVERT(bigint, pi.Quantity)) AS TotalUnits
    FROM Production.ProductInventory AS pi
    GROUP BY pi.ProductID
)
SELECT
    m.ProductID,
    m.ProductNumber,
    m.ProductName,
    COALESCE(t.TotalUnits, 0) AS TotalUnitsAcrossLocations,
    m.ReorderPoint,
    m.SafetyStockLevel,
    CASE WHEN COALESCE(t.TotalUnits, 0) < m.ReorderPoint
         THEN m.ReorderPoint - COALESCE(t.TotalUnits, 0) ELSE 0
    END AS UnitsToReorderPoint,
    CASE WHEN COALESCE(t.TotalUnits, 0) < m.SafetyStockLevel
         THEN m.SafetyStockLevel - COALESCE(t.TotalUnits, 0) ELSE 0
    END AS UnitsToSafetyStock
FROM MaterialScope AS m
LEFT JOIN ProductTotals AS t
    ON t.ProductID = m.ProductID
ORDER BY m.ProductName;

SELECT
    pi.ProductID,
    p.Name AS ProductName,
    pi.LocationID,
    l.Name AS LocationName,
    SUM(CONVERT(bigint, pi.Quantity)) AS UnitsAtLocation
FROM Production.ProductInventory AS pi
INNER JOIN Production.Product AS p
    ON p.ProductID = pi.ProductID
INNER JOIN Production.Location AS l
    ON l.LocationID = pi.LocationID
INNER JOIN Production.ProductSubcategory AS ps
    ON ps.ProductSubcategoryID = p.ProductSubcategoryID
INNER JOIN Production.ProductCategory AS pc
    ON pc.ProductCategoryID = ps.ProductCategoryID
WHERE pc.Name = N'Components'
  AND p.MakeFlag = 0
  AND p.FinishedGoodsFlag = 0
GROUP BY pi.ProductID, p.Name, pi.LocationID, l.Name
ORDER BY p.Name, pi.LocationID;

;WITH MonthlyPurchases AS
(
    SELECT
        pod.ProductID,
        p.Name AS ProductName,
        poh.VendorID,
        v.Name AS VendorName,
        DATEFROMPARTS(YEAR(poh.OrderDate), MONTH(poh.OrderDate), 1) AS PurchaseMonth,
        SUM(CONVERT(decimal(19, 4), pod.OrderQty)) AS UnitsOrdered,
        SUM(CONVERT(decimal(19, 4), pod.ReceivedQty)) AS UnitsReceived,
        SUM(CONVERT(decimal(19, 4), pod.RejectedQty)) AS UnitsRejected,
        SUM(CONVERT(decimal(19, 4), pod.UnitPrice)
            * CONVERT(decimal(19, 4), pod.ReceivedQty))
            / NULLIF(SUM(CONVERT(decimal(19, 4), pod.ReceivedQty)), 0)
            AS WeightedReceivedUnitPrice
    FROM Purchasing.PurchaseOrderHeader AS poh
    INNER JOIN Purchasing.PurchaseOrderDetail AS pod
        ON pod.PurchaseOrderID = poh.PurchaseOrderID
    INNER JOIN Production.Product AS p
        ON p.ProductID = pod.ProductID
    INNER JOIN Purchasing.Vendor AS v
        ON v.BusinessEntityID = poh.VendorID
    INNER JOIN Production.ProductSubcategory AS ps
        ON ps.ProductSubcategoryID = p.ProductSubcategoryID
    INNER JOIN Production.ProductCategory AS pc
        ON pc.ProductCategoryID = ps.ProductCategoryID
    WHERE pc.Name = N'Components'
      AND p.MakeFlag = 0
      AND p.FinishedGoodsFlag = 0
      AND @CutoffDate IS NOT NULL
      AND poh.OrderDate >= DATEADD(year, -1, @CutoffDate)
      AND poh.OrderDate < DATEADD(day, 1, @CutoffDate)
      AND poh.Status IN (2, 4)
    GROUP BY
        pod.ProductID, p.Name, poh.VendorID, v.Name,
        DATEFROMPARTS(YEAR(poh.OrderDate), MONTH(poh.OrderDate), 1)
),
PriceTrend AS
(
    SELECT
        mp.*,
        LAG(mp.PurchaseMonth) OVER
        (
            PARTITION BY mp.ProductID, mp.VendorID
            ORDER BY mp.PurchaseMonth
        ) AS PriorPurchaseMonth,
        LAG(mp.WeightedReceivedUnitPrice) OVER
        (
            PARTITION BY mp.ProductID, mp.VendorID
            ORDER BY mp.PurchaseMonth
        ) AS PriorMonthWeightedPrice
    FROM MonthlyPurchases AS mp
)
SELECT
    ProductID,
    ProductName,
    VendorID,
    VendorName,
    PurchaseMonth,
    UnitsOrdered,
    UnitsReceived,
    UnitsRejected,
    UnitsRejected / NULLIF(UnitsReceived, 0) AS RejectedRate,
    UnitsReceived
        / NULLIF(
            SUM(UnitsReceived) OVER (PARTITION BY ProductID, PurchaseMonth), 0
        ) AS VendorReceivedShare,
    CAST(WeightedReceivedUnitPrice AS decimal(19, 4))
        AS WeightedReceivedUnitPrice,
    CAST(
        CASE WHEN DATEDIFF(month, PriorPurchaseMonth, PurchaseMonth) = 1
             THEN WeightedReceivedUnitPrice
                  / NULLIF(PriorMonthWeightedPrice, 0) - 1
        END
        AS decimal(9, 6)
    ) AS MonthOverMonthPriceChange
FROM PriceTrend
ORDER BY ProductName, VendorName, PurchaseMonth;
GO
