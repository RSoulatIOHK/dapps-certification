import React, { FC, useEffect, useState } from "react";
import FormGroup from "@mui/material/FormGroup";
import FormControlLabel from "@mui/material/FormControlLabel";
import Checkbox from "@mui/material/Checkbox";

const ColViz: FC<any> = ({ columns, updateColumnOptions }) => {
  const [columnDetails, setColumnDetails] = useState([]);

  useEffect(() => {
    const columnCopy = updateColumnDetails(columns);
    setColumnDetails(columnCopy);
  }, [columns]);

  useEffect(() => {
    updateColumnOptions(columnDetails);
  }, [columnDetails]);

  const handleChange = (e: any, id: any) => {
    e.stopPropagation();
    const updatedColumns = columnDetails.map((column: any) => {
      if (column.accessor === id) {
        column.columnVisible = e.target.checked;
      }
      return column;
    });
    atLeastOneItemChecked(updatedColumns);
    // setColumnDetails(updatedColumns);
  };
  const atLeastOneItemChecked = (colArray: any) => {
    const find = colArray.filter((column: any) => column.columnVisible === true);
    if (find.length === 1) {
      const updatedColumn = colArray.map((column: any) => {
        if (find[0].accessor === column.accessor) {
          column.checkBoxDisabled = true;
        }
        return column;
      });
      setColumnDetails(updatedColumn);
    } else {
      const updatedColumn = colArray.map((column: any) => {
        column.checkBoxDisabled = false;
        return column;
      });
      setColumnDetails(updatedColumn);
    }
  };

  const updateColumnDetails = (columnArray: any) => {
    const columnCopy = JSON.parse(JSON.stringify(columnArray));
    return columnCopy.map((column: any) => {
      const columnVisible = column.columnVisible === false ? false : true;
      return {
        ...column,
        columnVisible: columnVisible,
      };
    });
  };
  return (
    <div className="colviz-wrapper">
      <ul>
        {columnDetails.map((column: any, index: any) => {
          if (column.Header.length) {
            return (
              <li key={index}>
                <FormGroup>
                  <FormControlLabel
                    control={
                      <Checkbox
                        checked={column.columnVisible}
                        onChange={(e) => handleChange(e, column.accessor)}
                        disabled={column.checkBoxDisabled}
                      />
                    }
                    label={column.Header}
                  />
                </FormGroup>
              </li>
            );
          } else {
            return <></>
          }
        })}
      </ul>
    </div>
  );
}

export default ColViz;